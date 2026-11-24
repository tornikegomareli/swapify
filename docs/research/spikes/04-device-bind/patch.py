#!/usr/bin/env python3
"""Builds a patch dylib from the files in edits/<version>/ that binds to the app instead of
defining its own copies of the app's types. For each file:

  1. ir       the build's own swift-frontend command for App/<file> (from build/build.log,
              rewritten like swapify's FrontendCommand.patch), with -emit-ir instead of -c, and the
              edited file in place of the original. Same basename, so private names do not change.
  2. rewrite  rewrite_ir.py: type entities become imports of the app's symbols.
  3. clang    xcrun clang -c on the rewritten IR.
then for the patch:
  4. link     one dylib with -undefined dynamic_lookup, as swapify links patches.
  5. codesign with the certificate that signed the app.

    python3 -I patch.py <version>      -> build/patches/<version>/patch_<version>.dylib
Prints one line per step with its time (summed over the files).
"""

import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
APP = os.path.join(BUILD, "DerivedData/Build/Products/Debug-iphoneos/Bind.app")
ORIGINAL = os.path.join(HERE, "App/Model.swift")


def frontend_command(original=ORIGINAL):
    for line in open(os.path.join(BUILD, "build.log"), errors="replace"):
        if "swift-frontend -frontend -c " in line and f"-primary-file {original}" in line:
            return shlex.split(line.strip())
    sys.exit(f"no frontend command for {original} in build/build.log")


def ir_command(command, original, edited, output):
    """swapify's FrontendCommand.patch, plus -emit-ir and the edited file in place of the original."""
    result, i = [], 0
    while i < len(command):
        arg = command[i]
        value = command[i + 1] if i + 1 < len(command) else ""
        if arg == "-primary-file":
            result += ["-primary-file", edited] if value == original else [value]
            i += 2
        elif arg in ("-o", "-supplementary-output-file-map", "-serialize-diagnostics-path", "-index-store-path",
                     "-index-unit-output-path") or (arg.startswith("-emit-") and arg.endswith("-path")):
            i += 2
        elif arg in ("-frontend-parseable-output", "-g") or arg.startswith(("-debug-info-format", "-dwarf-version")):
            i += 1  # no debug info: the rewrite drops definitions that DWARF would still name
        else:
            result.append(arg)
            i += 1
    result[result.index("-c")] = "-emit-ir"
    return result + ["-o", output]


def run(step, argv, timings):
    t = time.perf_counter()
    p = subprocess.run(argv, capture_output=True, text=True)
    timings[step] = timings.get(step, 0) + time.perf_counter() - t
    if p.returncode:
        sys.exit(f"{step} failed:\n{' '.join(argv)}\n{p.stdout}{p.stderr}")
    return p.stdout + p.stderr


def app_certificate():
    certs = os.path.join(BUILD, "certs")
    os.makedirs(certs, exist_ok=True)
    subprocess.run(["codesign", "-d", f"--extract-certificates={certs}/cert", APP], capture_output=True)
    out = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", f"{certs}/cert0", "-noout", "-fingerprint",
                          "-sha1"], capture_output=True, text=True).stdout
    return out.strip().split("=")[1].replace(":", "")


def main():
    version = sys.argv[1]
    edits = os.path.join(HERE, "edits", version)
    out = os.path.join(BUILD, "patches", version)
    os.makedirs(out, exist_ok=True)
    dylib = os.path.join(out, f"patch_{version}.dylib")
    sdk = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True,
                         text=True).stdout.strip()
    timings, objects, reports = {}, [], []
    for file in sorted(f for f in os.listdir(edits) if f.endswith(".swift")):
        original, stem = os.path.join(HERE, "App", file), os.path.join(out, file[:-len(".swift")])
        command = frontend_command(original)
        run("compile to IR", ir_command(command, original, os.path.join(edits, file), stem + ".ll"), timings)
        reports.append(f"{file}: " + run("rewrite IR", [sys.executable, "-I", os.path.join(HERE, "rewrite_ir.py"),
                                                       stem + ".ll", stem + ".rewritten.ll",
                                                       os.path.join(BUILD, "app-exports.txt")], timings).strip())
        run("clang", ["xcrun", "clang", "-c", "-target", "arm64-apple-ios27.0", "-O0", stem + ".rewritten.ll",
                      "-o", stem + ".o"], timings)
        objects.append(stem + ".o")
    toolchain = os.path.dirname(os.path.dirname(command[0]))
    run("link", ["xcrun", "clang", "-target", "arm64-apple-ios27.0", "-isysroot", sdk, "-dynamiclib", *objects,
                 "-o", dylib, "-install_name", f"@rpath/patch_{version}.dylib", "-undefined", "dynamic_lookup",
                 "-Wl,-w", f"-L{sdk}/usr/lib/swift", f"-L{toolchain}/lib/swift/iphoneos"], timings)
    run("codesign", ["codesign", "--force", "--sign", app_certificate(), dylib], timings)

    print("\n".join(reports))
    for step, seconds in timings.items():
        print(f"{version} {step:<14} {seconds * 1000:7.0f} ms")
    print(f"{version} {'total':<14} {sum(timings.values()) * 1000:7.0f} ms -> {os.path.relpath(dylib, HERE)}")


if __name__ == "__main__":
    main()
