#!/usr/bin/env python3
"""Rewrites the LLVM IR of a patch so that it binds to the app's types instead of defining copies.

    rewrite_ir.py <in.ll> <out.ll> <app exports>     (app exports: `dyld_info -exports` output)

1. Import: every global or alias the app exports, except chain roots ($s…TX) and replacement keys
   ($s…Tx), becomes an external declaration: type metadata (N), descriptors (Mn, Mc), witness
   tables (WP), field offsets (Wvd), static storage (vp), method and property descriptors. So do
   the accessor functions the app exports (Ma, vau, Wl, Wa). dyld binds them to the app at dlopen.
   Code that names a type's metadata as a constant getelementptr into the patch's $s…Mf gets the
   imported $s…N instead.
2. Keep: every other function with external linkage (the new bodies) and every chain root, plus
   everything they reference. Whatever is left is dropped: the patch's own metadata and the records
   that would register it (__swift5_types, __swift5_proto, __swift5_fieldmd, __objc_classlist).
3. A direct symbolic reference to an imported descriptor (byte 1 + 32-bit offset) cannot point into
   another image, so it becomes an indirect one (byte 2 + offset to a local `got.` pointer), which is
   what Swift emits for types of other modules.
Prints what it did, and exits with an error if a kept definition still needs a relative reference
to an imported symbol.
"""

import re
import sys

NAME = r'@("(?:[^"\\]|\\.)+"|[-a-zA-Z$._0-9]+)'
ACCESSORS = ("Ma", "vau", "Wl", "Wa")


def bare(token):
    return token[1:-1] if token.startswith('"') else token


def quoted(name):
    return f'@"{name}"'


def parse(lines):
    """Splits the module into ('global'|'function'|'other', name, [lines])."""
    entities, i = [], 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("define "):
            name = bare(re.search(NAME, line).group(1))
            j = i
            while lines[j].rstrip() != "}":
                j += 1
            entities.append(("function", name, lines[i:j + 1]))
            i = j + 1
            continue
        m = re.match(NAME + r" = ", line)
        if m:
            entities.append(("global", bare(m.group(1)), [line]))
        else:
            entities.append(("other", None, [line]))
        i += 1
    return entities


def references(text, own):
    return {bare(m.group(1)) for m in re.finditer(NAME, text)} - {own}


def declaration(define_line):
    """`define <ret> @f(<params>) #n {` -> `declare <ret> @f(<types>) #n`."""
    head = define_line[len("define "):].rsplit("{", 1)[0].strip()
    head = re.sub(r"\s*!dbg !\d+", "", head)
    for linkage in ("internal ", "private ", "linkonce_odr ", "hidden ", "protected ", "dso_local "):
        head = head.replace(linkage, "")
    # Drop parameter names: `i64 %0` -> `i64`.
    head = re.sub(r"(\S) %[-a-zA-Z$._0-9]+(?=[,)])", r"\1", head)
    return f"declare {head}\n"


def main():
    src, dst, exports_file = sys.argv[1:4]
    exported = set()
    for line in open(exports_file):
        m = re.match(r"\s*0x[0-9A-Fa-f]+\s+_(\S+)", line)
        if m:
            exported.add(m.group(1))
    lines = open(src).readlines()
    entities = parse(lines)
    defined = {name: (kind, body) for kind, name, body in entities if name}

    imported = set()
    for kind, name, body in entities:
        if kind == "global" and name in exported and not name.endswith(("TX", "Tx")):
            imported.add(name)
        if kind == "function" and name in exported and name.endswith(ACCESSORS):
            imported.add(name)

    # Code names a type's metadata as the alias's expression (a constant getelementptr into the
    # patch's full metadata $s…Mf), not as the alias $s…N. Point it at the imported alias instead.
    aliases = {}
    for kind, name, body in entities:
        m = re.match(NAME + r" = alias [^,]+, (getelementptr .*\))\s*$", body[0]) if kind == "global" else None
        if m and name in imported:
            aliases[m.group(2)] = quoted(name)
    texts, substituted = {}, 0
    for kind, name, body in entities:
        if not name or name in imported:
            continue
        text = "".join(body)
        for expression, alias in aliases.items():
            if expression in text:
                substituted += text.count(expression)
                text = text.replace(expression, alias)
        texts[name] = text

    roots = [name for kind, name, body in entities if name and name not in imported and (
        (kind == "function" and not re.match(r"define (internal|private|linkonce_odr|weak_odr)", body[0]))
        or name.endswith(("TX", "Tx")))]
    reachable, stack = set(), list(roots)
    while stack:
        name = stack.pop()
        if name in reachable or name in imported or name not in defined:
            continue
        reachable.add(name)
        stack += references(texts[name], name)

    out, got_needed, converted, bad = [], set(), 0, []
    for kind, name, body in entities:
        if kind == "other":
            out += body
        elif name in ("llvm.used", "llvm.compiler.used"):
            keep = [r for r in references(body[0], name) if r in reachable]
            if keep:
                items = ", ".join(f"ptr {quoted(r)}" for r in sorted(keep))
                out.append(f'@{name} = appending global [{len(keep)} x ptr] [{items}], section "llvm.metadata"\n')
        elif name in imported:
            out.append(declaration(body[0]) if kind == "function" else f"{quoted(name)} = external global i8, align 8\n")
        elif name in reachable:
            text = texts[name]

            def to_indirect(m):
                nonlocal converted
                target = bare(m.group(1))
                if target not in imported:
                    return m.group(0)
                converted += 1
                got_needed.add(target)
                return f"i8 2, i32 trunc (i64 sub (i64 ptrtoint (ptr {quoted('got.' + target)} to i64)"

            text = re.sub(r"i8 1, i32 trunc \(i64 sub \(i64 ptrtoint \(ptr " + NAME + r" to i64\)", to_indirect, text)
            for m in re.finditer(r"sub \(i64 ptrtoint \(ptr " + NAME + r" to i64\)", text):
                if bare(m.group(1)) in imported:
                    bad.append((name, bare(m.group(1))))
            out.append(text)
    for target in sorted(got_needed):
        if "got." + target not in defined:
            out.append(f"{quoted('got.' + target)} = private unnamed_addr constant ptr {quoted(target)}\n")
    open(dst, "w").writelines(out)

    kinds = {}
    for name in imported:
        suffix = next((s for s in ("TX", "Ma", "vau", "Wl", "Wa", "Wvd", "WP", "Mn", "Mc", "Mm", "MV", "Tq", "vpZ",
                                   "vp", "N") if name.endswith(s)), "other")
        kinds[suffix] = kinds.get(suffix, 0) + 1
    dropped = [n for k, n, b in entities if n and n not in imported and n not in reachable
               and n not in ("llvm.used", "llvm.compiler.used")]
    print("imported from the app: " + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items())))
    print(f"kept: {sum(1 for n in reachable if defined[n][0] == 'function')} functions, "
          f"{sum(1 for n in reachable if n.endswith('TX'))} chain roots; dropped {len(dropped)} definitions; "
          f"{converted} symbolic references made indirect; {substituted} direct metadata references "
          f"now use the app's $s…N")
    if bad:
        for name, target in bad:
            print(f"relative reference from {name} to imported {target}")
        sys.exit(1)


if __name__ == "__main__":
    main()
