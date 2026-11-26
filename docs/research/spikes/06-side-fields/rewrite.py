"""Spike: rewrite a patch's IR so stored properties added to an existing class live in a side table.
usage: rewrite.py original.ll edited.ll out.ll [--sil edited.sil] [--redirect-accessor MANGLED]

--sil also rewrites vtable calls, which a non-final class needs: a new stored property adds a field
offset word (and vtable entries) in front of every method's slot. The edited file's SIL names the class
and member of each `class_method`; they match the IR's vtable loads in the same function, in order. A
call to an existing member gets its slot in the app's metadata. A call to a new member becomes a direct
call to the patch's implementation: no class the app was built with can override a member it has never
seen. A count or slot that does not match stops the rewrite.

--redirect-accessor makes the patch's metadata accessor for MANGLED (e.g. $s3App5ModelC) call the
app's, through swp_app_<Name>_Ma in runtime.m. It stands in for the 16-byte jump that Agent/Patcher.m
writes in the simulator, which a macOS process cannot write. It is not part of the side-table rewrite."""
import re, sys

original, edited = open(sys.argv[1]).read(), open(sys.argv[2]).read()
redirect = sys.argv[sys.argv.index('--redirect-accessor') + 1] if '--redirect-accessor' in sys.argv else None
sil = open(sys.argv[sys.argv.index('--sil') + 1]).read() if '--sil' in sys.argv else None

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
    """The class's own fields: (name, mangled type symbol), in order, from its field descriptor <type>MF."""
    line = global_line(ir, mangled + 'MF')
    if not line: return []
    refs = re.findall(r'ptrtoint \(ptr (@"[^"]+"|@[\w.]+) to i64\), i64 ptrtoint \(ptr getelementptr', line)
    fields = []
    for t, n in zip(refs[0::2], refs[1::2]):  # each field refers to its type, then its name
        s = re.search(r'^@"?' + re.escape(n.strip('@').strip('"')) + r'"? = .*c"([^"]*)\\00"', ir, re.M)
        fields.append((s.group(1) if s else '?', t))
    return fields

def superclass(ir, mangled):
    """The superclass a field descriptor names, as `$s…C`, or None."""
    line = global_line(ir, mangled + 'MF')
    m = line and re.search(r'= \w+ (?:\w+ )?\{ [^}]* \} \{ (.*) \}', line)
    second = elements(m.group(1))[1] if m else 'i32 0'
    ref = re.search(r'ptrtoint \(ptr @"symbolic _+ (\w+C)" to', second)
    return '$s' + ref.group(1) if ref else None

def all_fields(ir, mangled):
    """Every stored field of an object of the class, superclass fields first: (name, type symbol, declaring class).
    The class's LLVM struct type lays them out in this order."""
    parent = superclass(ir, mangled)
    return (all_fields(ir, parent) if parent else []) + [(n, t, mangled) for n, t in field_names(ir, mangled)]

def field_elements(body):
    """Struct element index of each stored field: element 0 is the object header, `[N x i8]` is padding."""
    return [i for i, e in enumerate(elements(body)) if i > 0 and not re.fullmatch(r'\[\d+ x i8\]', e)]

old_types, new_types = struct_types(original), struct_types(edited)
out = edited
helpers, plans = {}, {}
for llvm_type, new_body in new_types.items():
    old_body = old_types.get(llvm_type)
    if old_body is None or old_body == new_body: continue
    mangled = '$s' + llvm_type[2:]  # %T3App7CounterC -> $s3App7CounterC
    old_fields, new_fields = all_fields(original, mangled), all_fields(edited, mangled)
    old_keys = [(f[2], f[0]) for f in old_fields]
    assert [(f[2], f[0]) for f in new_fields if (f[2], f[0]) in old_keys] == old_keys, "existing fields moved"
    old_index = dict(zip(old_keys, field_elements(old_body)))
    # The struct type stops at the first field of resilient layout (@Observable's registrar); later fields are
    # reached through their offset globals, which the agent copies from the app. New fields must come before.
    covered = len(field_elements(new_body))
    assert all((f[2], f[0]) in old_keys for f in new_fields[covered:]), f'{llvm_type}: a new field after a resilient one'
    plan = {}
    for (name, type_symbol, owner), element in zip(new_fields, field_elements(new_body)):
        plan[element] = ('old', old_index[(owner, name)]) if (owner, name) in old_index else ('side', f'{owner}.{name}')
        if plan[element][0] == 'side' and f'{owner}.{name}' not in helpers:
            helpers[f'{owner}.{name}'] = (owner, name, type_symbol)
    plans[llvm_type] = plan
    out = out.replace(f'{llvm_type} = type <{{ {new_body} }}>', f'{llvm_type} = type <{{ {old_body} }}>')

def helper_ir(key, owner, name, type_symbol):
    """The function that returns the address of a side field, running its initial value on first use."""
    def initializer(field):
        return re.search(r'^define [^@]*swiftcc (.*?) @"(' + re.escape(owner) + str(len(field)) + re.escape(field)
                         + r'(?:33_[0-9A-F]{32}LL)?\w*vpfi)"\((.*?)\)', edited, re.M)
    # Backing storage made by a macro (@Observable's _count) takes the initial value of the property it backs.
    pfi = initializer(name) or (name.startswith('_') and initializer(name[1:]))
    assert pfi, f'{name} has no initial value'
    ret, pfi_name, params = pfi.groups()
    if 'sret' in params:
        init = f'  call swiftcc void @"{pfi_name}"(ptr noalias sret({ret}) %slot)\n'  # spike: not exercised
    else:
        init = f'  %value = call swiftcc {ret} @"{pfi_name}"()\n  store {ret} %value, ptr %slot, align 8\n'
    return (f'@"swapify.key.{key}" = private unnamed_addr constant [{len(key) + 1} x i8] c"{key}\\00"\n'
            f'define private ptr @"swapify.side.{key}"(ptr %object, i1 %initializing) {{\nentry:\n'
            f'  %fresh = alloca i1, align 1\n'
            f'  %slot = call ptr @SWPSideField(ptr %object, ptr @"swapify.key.{key}", ptr {type_symbol}, ptr @"{owner}Mn", i1 %initializing, ptr %fresh)\n'
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
        lines[i] = f'{result} = call ptr @"swapify.side.{target[1]}"(ptr {base}, i1 {initializing})'
    rewritten += 1
leftovers = [l for l in lines if any(t in l for t in plans) and 'getelementptr' in l and '= type' not in l
             and not gep.match(l)]
assert not leftovers, f'unhandled accesses: {leftovers[:3]}'

# ── Vtable calls (--sil) ─────────────────────────────────────────────────────────────────────
SIZES = {'ptr': 8, 'i64': 8, 'i32': 4, 'i16': 2, 'i8': 1}

def slots(ir, mangled):
    """Implementation symbol -> vtable slot, in words from the address point of the class's full metadata."""
    line, alias = global_line(ir, mangled + 'Mf'), global_line(ir, mangled + 'N')
    if not line or not alias: return None
    m = re.search(r'= \w+ (?:\w+ )?<\{ (.*?) \}> <\{ (.*) \}>, align', line)
    types, values = elements(m.group(1)), elements(m.group(2))
    point = int(re.search(r'i32 0, i32 (\d+)\)', alias).group(1))
    offsets, at = [], 0
    for t in types:
        offsets.append(at)
        at += SIZES[t]
    result = {}
    for t, v, o in zip(types, values, offsets):
        f = re.fullmatch(r'ptr @"?([^"]+)"?', v)
        if t == 'ptr' and f and o > offsets[point] and (o - offsets[point]) % 8 == 0:
            result.setdefault(f.group(1), (o - offsets[point]) // 8)
    return result

def sil_vtables(sil):
    """SIL class name -> (mangled class, {member: implementation symbol})."""
    tables = {}
    for name, body in re.findall(r'^sil_vtable (?:\[\w+\] )?(\S+) \{\n(.*?)^\}', sil, re.M | re.S):
        # Overloads share a name (@Observable's four shouldNotifyObservers), so a member is its name and type.
        entries = {f'{m} : {t}': impl for m, t, impl in re.findall(r'^\s+(#\S+?): (.*) : @(\S+)', body, re.M)}
        entries.update(re.findall(r'^\s+(#\S+?deinit!deallocator): @(\S+)', body, re.M))
        dealloc = next((v for k, v in entries.items() if k.endswith('deinit!deallocator')), None)
        tables[name] = (dealloc[:-2] if dealloc else None, entries)  # $s3App7CounterCfD -> $s3App7CounterC
    return tables

def sil_calls(sil):
    """SIL function symbol -> the members its class_method instructions name, in order."""
    return {name: [f'{m} : {t}' for m, t in re.findall(r'= class_method %\S+, (#\S+) : (.*?), \$@', body)]
            for name, body in re.findall(r'^sil [^\n]*?@(\S+) : [^\n]*\{\n(.*?)^\} // end sil function', sil, re.M | re.S)}

moved = direct = 0
if sil:
    tables, calls = sil_vtables(sil), sil_calls(sil)
    changed = {}  # mangled class -> (slots as built, slots in the patch), for classes whose slots moved
    for mangled, entries in tables.values():
        old, new = (slots(original, mangled), slots(edited, mangled)) if mangled else (None, None)
        if old and new and any(old.get(impl) != slot for impl, slot in new.items()):
            changed[mangled] = (old, new)
    isa = re.compile(r'^\s*(%\S+) = load ptr, ptr %\S+, align 8$')
    slot_gep = re.compile(r'^\s*(%\S+) = getelementptr inbounds ptr, ptr (%\S+), i64 (\d+)$')
    slot_load = re.compile(r'^(\s*%\S+) = load ptr, ptr (%\S+), align 8, !invariant.load !\d+$')

    def rewrite_calls(function, sites):
        global moved, direct
        members = calls.get(function, [])
        assert len(members) == len(sites), f'{function}: {len(members)} class_method in SIL, {len(sites)} vtable loads in IR'
        for member, (gep_line, load_line, slot) in zip(members, sites):
            mangled, entries = tables.get(member[1:].split(' : ')[0].rsplit('.', 1)[0], (None, {}))
            if mangled not in changed: continue
            old, new = changed[mangled]
            impl = entries[member]
            assert new.get(impl) == slot, f'{function}: {member} is slot {slot} in the IR, {new.get(impl)} in the metadata'
            if impl in old:
                lines[gep_line] = re.sub(r'i64 \d+$', f'i64 {old[impl]}', lines[gep_line])
                moved += 1
            else:
                assert all(e.get(member) in (None, impl) for _, e in tables.values()), f'{member} is overridden'
                lines[load_line] = f'{slot_load.match(lines[load_line]).group(1)} = getelementptr i8, ptr @"{impl}", i64 0'
                direct += 1

    function, sites, isas = None, [], set()
    for i, line in enumerate(lines):
        if line.startswith('define '):
            function, sites, isas = re.search(r'@"?([^"(]+)"?\(', line).group(1), [], set()
        elif line == '}' and function:
            rewrite_calls(function, sites)
            function = None
        elif function:
            if (m := isa.match(line)):
                isas.add(m.group(1))
            elif (m := slot_gep.match(line)) and m.group(2) in isas and i + 1 < len(lines) \
                    and (n := slot_load.match(lines[i + 1])) and n.group(2) == m.group(1):
                sites.append((i, i + 1, int(m.group(3))))
    print(f'{len(changed)} class(es) with moved slots: {moved} vtable call(s) to the app\'s slots, {direct} made direct')

out = '\n'.join(lines) + '\n' + ''.join(helper_ir(k, *v) for k, v in helpers.items()) \
    + 'declare ptr @SWPSideField(ptr, ptr, ptr, ptr, i1, ptr)\n'
if redirect:
    name = re.sub(r'^\$s\d*\w*?(\d+)(\w+)C$', r'\2', redirect)  # $s3App5ModelC -> Model
    accessor = re.search(r'^define ([^@]*)@"' + re.escape(redirect) + r'Ma"\(i64 %0\)([^{]*)\{\n.*?^\}\n', out, re.M | re.S)
    assert accessor, 'no metadata accessor'
    out = out.replace(accessor.group(0), f'define {accessor.group(1)}@"{redirect}Ma"(i64 %0){accessor.group(2)}{{\nentry:\n'
                      f'  %r = call swiftcc %swift.metadata_response @swp_app_{name}_Ma(i64 %0)\n'
                      f'  ret %swift.metadata_response %r\n}}\ndeclare swiftcc %swift.metadata_response @swp_app_{name}_Ma(i64)\n')
open(sys.argv[3], 'w').write(out)
print(f'{len(plans)} class(es), {rewritten} field accesses rewritten, {len(helpers)} side field(s)')
