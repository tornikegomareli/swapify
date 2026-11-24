#!/usr/bin/env python3
"""Which app flags the binding needs: compiles each edited file (App/Model.swift,
App/ProbeView.swift) with the build's own frontend command, with and without -enable-testing and -enable-private-imports, and reports for each
variant which symbols a patch imports (build/patches/v2/patch_v2.dylib) are exported by the
objects (`external`) or not (`private external` is hidden, `non-external` is local; the app
would export neither).

    python3 -I flags.py
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import patch  # noqa: E402


def main():
    needed = [l.strip()[1:] for l in subprocess.run(["xcrun", "nm", "-u", os.path.join(
        HERE, "build/patches/v2/patch_v2.dylib")], capture_output=True, text=True).stdout.split()
        if l.startswith("_$s4Bind")]
    files = sorted(f for f in os.listdir(os.path.join(HERE, "edits", "v2")) if f.endswith(".swift"))
    out = os.path.join(HERE, "build", "flags")
    os.makedirs(out, exist_ok=True)
    variants = [("both flags", []), ("no -enable-private-imports", ["-enable-private-imports"]),
                ("no -enable-testing", ["-enable-testing"]),
                ("neither", ["-enable-testing", "-enable-private-imports"])]
    print(f"{len(needed)} symbols the patch imports: " + ", ".join(needed))
    for label, drop in variants:
        status = {}
        for file in files:
            original = os.path.join(HERE, "App", file)
            command = [a for a in patch.ir_command(patch.frontend_command(original), original, original, "x")
                       if a not in drop][:-2]
            command[command.index("-emit-ir")] = "-c"
            obj = os.path.join(out, label.replace(" ", "_") + "_" + file[:-len(".swift")] + ".o")
            p = subprocess.run(command + ["-o", obj], capture_output=True, text=True)
            if p.returncode:
                sys.exit(f"{label} {file}: compile failed\n{p.stderr[:800]}")
            for line in subprocess.run(["xcrun", "nm", "-m", obj], capture_output=True, text=True).stdout.splitlines():
                if "(undefined)" in line:
                    continue
                m = re.search(r"\) (external|private external|non-external)(?: \[[^]]*\])* _(\S+)$", line)
                if m:
                    status[m.group(2)] = m.group(1)
        hidden = [n for n in needed if status.get(n) != "external"]
        print(f"{label:<28} exported {len(needed) - len(hidden)} of {len(needed)}"
              + ("" if not hidden else "; not exported: " + ", ".join(f"{n} ({status.get(n, 'absent')})"
                                                                    for n in hidden)))


if __name__ == "__main__":
    main()
