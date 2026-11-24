#!/usr/bin/env python3
"""Builds a bound patch of one Habits source file for the device (spike 04's pipeline):
the build's own swift-frontend command with -emit-ir, ../04-device-bind/rewrite_ir.py, clang -c,
a dylib linked with -undefined dynamic_lookup, signed with the app's certificate.

    python3 -I patch.py <source file as built> [<edited copy>] [<output dir>]

As a module: build(source, out_dir) -> (dylib path, [(step, seconds)]); raises CompileError with
the compiler's error lines.
"""

import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
APP = os.path.join(BUILD, "DerivedData/Build/Products/Debug-iphoneos/Habits.app")
REWRITE = os.path.join(HERE, "..", "04-device-bind", "rewrite_ir.py")
SDK = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()


class CompileError(Exception):
    pass


def frontend_command(original):
    for line in open(os.path.join(BUILD, "build.log"), errors="replace"):
        if "swift-frontend -frontend -c " in line and f"-primary-file {original}" in line:
            return shlex.split(line.strip())
    raise CompileError(f"no frontend command for {original} in build/build.log")


def ir_command(command, original, edited, output):
    """swapify's FrontendCommand.patch, plus -emit-ir instead of -c and no debug info."""
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
            i += 1
        else:
            result.append(arg)
            i += 1
    result[result.index("-c")] = "-emit-ir"
    return result + ["-o", output]


def certificate():
    out = subprocess.run(["openssl", "x509", "-inform", "DER", "-in", os.path.join(BUILD, "certs/cert0"), "-noout",
                          "-fingerprint", "-sha1"], capture_output=True, text=True).stdout
    return out.strip().split("=")[1].replace(":", "")


def build(original, out_dir, edited=None):
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.join(out_dir, os.path.basename(original)[:-len(".swift")])
    dylib = os.path.join(out_dir, "patch.dylib")
    command = frontend_command(original)
    toolchain = os.path.dirname(os.path.dirname(command[0]))
    steps = []

    def run(step, argv):
        t = time.perf_counter()
        p = subprocess.run(argv, capture_output=True, text=True)
        steps.append((step, time.perf_counter() - t))
        if p.returncode:
            errors = [l for l in (p.stdout + p.stderr).splitlines() if "error:" in l] or [(p.stdout + p.stderr)[-2000:]]
            raise CompileError("\n".join(errors[:20]))
        return p.stdout

    run("compile to IR", ir_command(command, original, edited or original, stem + ".ll"))
    report = run("rewrite IR", [sys.executable, "-I", REWRITE, stem + ".ll", stem + ".rewritten.ll",
                                os.path.join(BUILD, "app-exports.txt")])
    run("clang", ["xcrun", "clang", "-c", "-target", "arm64-apple-ios27.0", "-O0", stem + ".rewritten.ll",
                  "-o", stem + ".o"])
    run("link", ["xcrun", "clang", "-target", "arm64-apple-ios27.0", "-isysroot", SDK, "-dynamiclib", stem + ".o",
                 "-o", dylib, "-install_name", f"@rpath/{os.path.basename(out_dir)}.dylib", "-undefined",
                 "dynamic_lookup", "-Wl,-w", f"-L{SDK}/usr/lib/swift", f"-L{toolchain}/lib/swift/iphoneos"])
    run("codesign", ["codesign", "--force", "--sign", certificate(), dylib])
    return dylib, steps, report.strip()


if __name__ == "__main__":
    original = os.path.abspath(sys.argv[1])
    edited = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else None
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(BUILD, "patches", "manual")
    try:
        dylib, steps, report = build(original, out, edited)
    except CompileError as e:
        sys.exit(f"compile error:\n{e}")
    print(report)
    for step, seconds in steps:
        print(f"{step:<14} {seconds * 1000:6.0f} ms")
    print(f"{'total':<14} {sum(s for _, s in steps) * 1000:6.0f} ms -> {dylib} ({os.path.getsize(dylib)} bytes)")
