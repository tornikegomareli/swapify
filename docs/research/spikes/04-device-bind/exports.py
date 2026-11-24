#!/usr/bin/env python3
"""Which symbols of Model.swift the app exports, by kind.

    exports.py <nm -m output of the app>

A symbol is exported if `nm -m` says `external` (dyld can bind a patch to it). `non-external
(was private external)` is a hidden symbol: present in the symbol table, not bindable.
"""

import re
import sys

KINDS = [  # suffix, meaning
    ("Ma", "metadata accessor"),
    ("vau", "addressor"),
    ("Wl", "lazy witness table accessor"),
    ("Wa", "witness table accessor"),
    ("Wvd", "field offset"),
    ("WP", "witness table"),
    ("TX", "chain root"),
    ("Mn", "nominal type descriptor"),
    ("N", "type metadata"),
    ("Mc", "conformance descriptor"),
    ("vp", "global or static storage"),
    ("Wz", "lazy init token"),
]
# Declarations in Model.swift.
MODEL = re.compile(r"\$s4Bind(3BoxC|4ItemV|5TokenC|5StoreO|6Secret|6helper|7compute|7version|10secretText|"
                   r"17makeHelperClosure|7makeBox|8makeItem|10makeSecret|9makeItems|7tokenID|8hitsSeen|"
                   r"11boxMetadata|12itemMetadata|13greeterOfItem)")


def kind_of(name):
    for suffix, meaning in KINDS:
        if name.endswith(suffix):
            return suffix, meaning
    return None


def main():
    rows = {}
    for line in open(sys.argv[1]):
        m = re.match(r"\s*\S+ \(([^)]*)\) (external|non-external(?: \(was private external\))?|private external) (\S+)",
                     line)
        if not m or not MODEL.search(m.group(3)):
            continue
        section, status, name = m.groups()
        kind = kind_of(name)
        if not kind:
            continue
        exported = status == "external"
        rows.setdefault(kind, []).append((exported, status, name))
    print(f"{'kind':<34} {'exported':>8} {'hidden':>7}")
    for suffix, meaning in KINDS:
        entries = rows.get((suffix, meaning), [])
        if not entries:
            continue
        yes = sum(1 for e in entries if e[0])
        print(f"{suffix + ' ' + meaning:<34} {yes:>8} {len(entries) - yes:>7}")
        for exported, status, name in entries:
            if not exported:
                print(f"    hidden: {name} ({status})")


if __name__ == "__main__":
    main()
