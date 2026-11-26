"""Spike: rewrite a patch's IR so stored properties added to an existing class live in a side table.
usage: rewrite.py original.ll edited.ll out.ll [--redirect-accessor MANGLED]

--redirect-accessor makes the patch's metadata accessor for MANGLED (e.g. $s3App5ModelC) call the
app's, through swp_app_<Name>_Ma in runtime.m. It stands in for the 16-byte jump that Agent/Patcher.m
writes in the simulator, which a macOS process cannot write. It is not part of the side-table rewrite."""
import re, sys

original, edited = open(sys.argv[1]).read(), open(sys.argv[2]).read()
redirect = sys.argv[sys.argv.index('--redirect-accessor') + 1] if '--redirect-accessor' in sys.argv else None

def struct_types(ir):
    return {m.group(1): m.group(2) for m in re.finditer(r'^(%T\S+C) = type <\{ (.*) \}>$', ir, re.M)}

def elements(body):
    parts, depth, start = [], 0, 0
    for i, c in enumerate(body):
        if c in '<{[(': depth += 1
        elif c in '>}])': depth -= 1
        elif c == ',' and depth == 0:
            parts.append(body[start:i].strip()); start = i + 1
    parts.append(body[start:].strip())
    return parts

def global_line(ir, name):
    m = re.search(r'^@"' + re.escape(name) + r'" = .*$', ir, re.M)
    return m.group(0) if m else None

def field_names(ir, mangled):
    """Field names and mangled type symbols, in order, from the field descriptor <type>MF."""
    line = global_line(ir, mangled + 'MF')
    if not line: return None
    refs = re.findall(r'ptrtoint \(ptr (@"[^"]+"|@[\w.]+) to i64\), i64 ptrtoint \(ptr getelementptr', line)
    # refs pairs: (type, name) per field
    fields = []
    for t, n in zip(refs[0::2], refs[1::2]):
        nname = n.strip('@').strip('"')
        s = re.search(r'^@"?' + re.escape(nname) + r'"? = .*c"([^"]*)\\00"', ir, re.M)
        fields.append((s.group(1) if s else '?', t))
    return fields

def field_elements(body):
    """Struct element index of each stored field: element 0 is the object header, `[N x i8]` is padding."""
    return [i for i, e in enumerate(elements(body)) if i > 0 and not re.fullmatch(r'\[\d+ x i8\]', e)]

old_types, new_types = struct_types(original), struct_types(edited)
out = edited
helpers, plans = [], {}
for llvm_type, new_body in new_types.items():
    old_body = old_types.get(llvm_type)
    if old_body is None or old_body == new_body: continue
    mangled = '$s' + llvm_type[2:]  # %T3App7CounterC -> $s3App7CounterC
    old_fields, new_fields = field_names(original, mangled), field_names(edited, mangled)
    old_names = [f[0] for f in old_fields]
    assert [f[0] for f in new_fields if f[0] in old_names] == old_names, "existing fields moved"
    old_index = dict(zip(old_names, field_elements(old_body)))
    plan = {}
    for (name, type_symbol), element in zip(new_fields, field_elements(new_body)):
        plan[element] = ('old', old_index[name]) if name in old_index else ('side', name, type_symbol)
    plans[llvm_type] = plan
    out = out.replace(f'{llvm_type} = type <{{ {new_body} }}>', f'{llvm_type} = type <{{ {old_body} }}>')
    for element, target in plan.items():
        if target[0] != 'side': continue
        _, name, type_symbol = target
        key = f'{mangled}.{name}'
        helper = f'@"swapify.side.{key}"'
        def initializer(field):
            return re.search(r'^define [^@]*swiftcc (.*?) @"(' + re.escape(mangled) + str(len(field)) + re.escape(field)
                             + r'(?:33_[0-9A-F]{32}LL)?\w*vpfi)"\((.*?)\)', edited, re.M)
        # Backing storage made by a macro (@Observable's _count) takes the initial value of the property it backs.
        pfi = initializer(name) or (name.startswith('_') and initializer(name[1:]))
        assert pfi, f'{name} has no initial value'
        ret, pfi_name, params = pfi.groups()
        if 'sret' in params:
            init = f'  call swiftcc void @"{pfi_name}"(ptr noalias sret({ret}) %slot)\n'  # spike: not exercised
        else:
            init = f'  %value = call swiftcc {ret} @"{pfi_name}"()\n  store {ret} %value, ptr %slot, align 8\n'
        helpers.append(
            f'@"swapify.key.{key}" = private unnamed_addr constant [{len(key) + 1} x i8] c"{key}\\00"\n'
            f'define private ptr {helper}(ptr %object, i1 %initializing) {{\nentry:\n'
            f'  %fresh = alloca i1, align 1\n'
            f'  %slot = call ptr @SWPSideField(ptr %object, ptr @"swapify.key.{key}", ptr {type_symbol}, ptr @"{mangled}Mn", i1 %initializing, ptr %fresh)\n'
            f'  %isFresh = load i1, ptr %fresh, align 1\n  br i1 %isFresh, label %initialize, label %done\n'
            f'initialize:\n{init}  br label %done\ndone:\n  ret ptr %slot\n}}\n')

# Rewrite the field accesses, function by function (a designated initializer stores first values itself).
lines, function, rewritten = out.split('\n'), None, 0
gep = re.compile(r'^(\s*%\S+) = getelementptr inbounds(?: nuw)? (%T\S+C), ptr (%\S+), i32 0, i32 (\d+)$')
for i, line in enumerate(lines):
    if line.startswith('define '):
        function = re.search(r'@"?([^"(]+)"?\(', line).group(1)
    m = gep.match(line)
    if not m or m.group(2) not in plans: continue
    result, llvm_type, base, element = m.groups()
    target = plans[llvm_type][int(element)]
    if target[0] == 'old':
        lines[i] = line.replace(f'i32 0, i32 {element}', f'i32 0, i32 {target[1]}')
    else:
        initializing = 'true' if function.endswith('fc') else 'false'
        lines[i] = f'{result} = call ptr @"swapify.side.{"$s" + llvm_type[2:]}.{target[1]}"(ptr {base}, i1 {initializing})'
    rewritten += 1
leftovers = [l for l in lines if any(t in l for t in plans) and 'getelementptr' in l and '= type' not in l
             and not gep.match(l)]
assert not leftovers, f'unhandled accesses: {leftovers[:3]}'
out = '\n'.join(lines) + '\n' + '\n'.join(helpers) + 'declare ptr @SWPSideField(ptr, ptr, ptr, ptr, i1, ptr)\n'
if redirect:
    name = re.sub(r'^\$s\d*\w*?(\d+)(\w+)C$', r'\2', redirect)  # $s3App5ModelC -> Model
    accessor = re.search(r'^define ([^@]*)@"' + re.escape(redirect) + r'Ma"\(i64 %0\)([^{]*)\{\n.*?^\}\n', out, re.M | re.S)
    assert accessor, 'no metadata accessor'
    out = out.replace(accessor.group(0), f'define {accessor.group(1)}@"{redirect}Ma"(i64 %0){accessor.group(2)}{{\nentry:\n'
                      f'  %r = call swiftcc %swift.metadata_response @swp_app_{name}_Ma(i64 %0)\n'
                      f'  ret %swift.metadata_response %r\n}}\ndeclare swiftcc %swift.metadata_response @swp_app_{name}_Ma(i64)\n')
open(sys.argv[3], 'w').write(out)
print(f'{len(plans)} class(es), {rewritten} field accesses rewritten, {len(helpers)} side field(s)')
