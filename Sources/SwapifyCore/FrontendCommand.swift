import Foundation

/// Rewrites the build's own swift-frontend command into a patch command.
public enum FrontendCommand {
    /// Compiles only `primary` into `output`. Other primary files become plain
    /// inputs, and the build's supplementary outputs are dropped. The file keeps
    /// its path, so `private` names keep their mangling. A new file, which the
    /// command has as a plain input or in its file list, becomes the primary file.
    public static func patch(_ command: [String], primary: String, output: String) -> [String] {
        var result: [String] = []
        var marked = false
        var index = 0
        // With -filelist every source is already in the list, and swift-frontend
        // rejects plain input files next to it.
        let listed = command.contains("-filelist")
        while index < command.count {
            let argument = command[index]
            let value = index + 1 < command.count ? command[index + 1] : ""
            if argument == "-primary-file" {
                result += value == primary ? [argument, value] : (listed ? [] : [value])
                marked = marked || value == primary
                index += 2
            } else if argument == primary, !marked {
                result += ["-primary-file", primary]
                marked = true
                index += 1
            } else if dropsValue(argument) {
                index += 2
            } else if argument == "-frontend-parseable-output" {
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result + (marked ? [] : ["-primary-file", primary]) + ["-o", output]
    }

    /// `command` with `inputs` added as source files. A command that reads its
    /// inputs from a `-filelist` gets a copy of that list with them, written to `list`.
    public static func adding(_ inputs: [String], to command: [String], list: URL) throws -> [String] {
        guard !inputs.isEmpty else { return command }
        guard let index = command.firstIndex(of: "-filelist"), index + 1 < command.count else { return command + inputs }
        let listed = try String(contentsOfFile: command[index + 1], encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try (listed + inputs).map { $0 + "\n" }.joined().write(to: list, atomically: true, encoding: .utf8)
        var result = command
        result[index + 1] = list.path
        return result
    }

    /// The patch command for a device patch: LLVM IR instead of an object, without
    /// debug info, which would name definitions the binder drops. With `source`,
    /// that file is compiled in place of `primary`: the copy of the file as it was
    /// built, which the layout guard compares with the edit.
    public static func patchIR(_ command: [String], primary: String, source: String? = nil, output: String) -> [String] {
        patch(command, primary: primary, output: output).compactMap { argument in
            if argument == "-c" { return "-emit-ir" }
            if argument == primary, let source { return source }
            let debug = argument == "-g" || argument.hasPrefix("-debug-info-format") || argument.hasPrefix("-dwarf-version")
            return debug ? nil : argument
        }
    }

    /// Compiles a patch's IR, as rewritten, to an object with the clang next to swift-frontend.
    public static func compileIR(_ command: [String], ir: String, output: String) -> [String] {
        let usr = URL(fileURLWithPath: command[0]).deletingLastPathComponent().deletingLastPathComponent()
        let target = command.firstIndex(of: "-target").map { command[$0 + 1] } ?? ""
        return [usr.appendingPathComponent("bin/clang").path, "-c", "-target", target, "-O0", ir, "-o", output]
    }

    /// The patch command for the edit's SIL, where each vtable call names its class and
    /// member (SideFields). Without debug info, like `patchIR`.
    public static func patchSIL(_ command: [String], primary: String, output: String) -> [String] {
        patchIR(command, primary: primary, output: output).map { $0 == "-emit-ir" ? "-emit-sil" : $0 }
    }

    private static func dropsValue(_ argument: String) -> Bool {
        ["-o", "-supplementary-output-file-map", "-serialize-diagnostics-path", "-index-store-path",
         "-index-unit-output-path"].contains(argument)
            || (argument.hasPrefix("-emit-") && argument.hasSuffix("-path"))
    }

    /// Links patch objects into a dylib with the clang next to swift-frontend.
    /// App symbols stay undefined and bind to the running app at load time.
    public static func link(_ command: [String], objects: [String], output: String) -> [String] {
        func value(_ flag: String) -> String {
            guard let index = command.firstIndex(of: flag), index + 1 < command.count else { return "" }
            return command[index + 1]
        }
        // command[0] is <toolchain>/usr/bin/swift-frontend.
        let usr = URL(fileURLWithPath: command[0]).deletingLastPathComponent().deletingLastPathComponent()
        let sdk = value("-sdk")
        let platform = value("-target").hasSuffix("-simulator") ? "iphonesimulator" : "iphoneos"
        return [usr.appendingPathComponent("bin/clang").path, "-target", value("-target"),
                "-isysroot", sdk, "-dynamiclib"] + objects
            + ["-o", output, "-undefined", "dynamic_lookup", "-Wl,-w",
               "-L\(sdk)/usr/lib/swift", "-L\(usr.path)/lib/swift/\(platform)"]
    }
}
