import Foundation

/// Rewrites the build's own swift-frontend command into a patch command.
public enum FrontendCommand {
    /// Compiles only `primary` into `output`. Other primary files become plain
    /// inputs, and the build's supplementary outputs are dropped. The file keeps
    /// its path, so `private` names keep their mangling.
    public static func patch(_ command: [String], primary: String, output: String) -> [String] {
        var result: [String] = []
        var index = 0
        while index < command.count {
            let argument = command[index]
            let value = index + 1 < command.count ? command[index + 1] : ""
            if argument == "-primary-file" {
                result += value == primary ? [argument, value] : [value]
                index += 2
            } else if dropsValue(argument) {
                index += 2
            } else if argument == "-frontend-parseable-output" {
                index += 1
            } else {
                result.append(argument)
                index += 1
            }
        }
        return result + ["-o", output]
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
