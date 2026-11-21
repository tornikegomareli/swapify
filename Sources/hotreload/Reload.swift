import Foundation

/// Recompiles the edited files, loads them into the running app, refreshes
/// SwiftUI and takes a screenshot.
func reload(files: [String]) throws {
    let start = Date()
    var state = State.load()
    let generation = state.generation + 1
    // dlopen returns the already loaded image for a known path, so every
    // attempt, failed ones included, needs a new path.
    let attempt = "\(generation)-\(UUID().uuidString.prefix(8))"
    let directory = State.directory.appendingPathComponent("patches/\(attempt)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Compile each file with its original command, as the only primary file.
    var objects: [String] = []
    var linkFlags: [String] = []
    for file in files {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        guard let command = state.commands[path] else {
            throw CommandError(description: "No compile command for \(path). Run `hotreload build`.")
        }
        let object = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + ".o").path
        let result = try run(patchCommand(command, primary: path, output: object))
        guard result.status == 0 else {
            let errors = result.output.split(separator: "\n").filter { $0.contains("error:") }
            printJSON(["ok": false, "stage": "compile", "file": path, "errors": errors.map(String.init)])
            exit(1)
        }
        objects.append(object)
        linkFlags = linkSettings(command)
    }
    let compileMs = milliseconds(since: start)

    let dylib = directory.appendingPathComponent("patch_\(attempt).dylib").path
    let link = try run(["xcrun", "swiftc", "-emit-library"] + linkFlags + objects
                       + ["-o", dylib, "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])
    guard link.status == 0 else {
        printJSON(["ok": false, "stage": "link", "output": link.output])
        exit(1)
    }
    let linkMs = milliseconds(since: start) - compileMs

    let agent = AgentConnection()
    let load = try agent.send("load \(dylib)")
    guard load["ok"] as? Bool == true else {
        var report: [String: Any] = ["ok": false, "stage": "load", "agent": load]
        if load["needsRebuild"] as? Bool == true, let type = load["type"] as? String {
            report["needsRebuild"] = true
            report["type"] = try run(["xcrun", "swift-demangle", "--simplified", "--compact", type]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            report["hint"] = "Stored properties or class methods changed. Run `hotreload build` and `hotreload launch`."
        }
        printJSON(report)
        exit(1)
    }
    let refresh = try agent.send("refresh")
    state.generation = generation
    try state.save()

    Thread.sleep(forTimeInterval: 0.3)  // let the next frame render
    let image = try screenshot(state, name: "reload-\(generation)")
    printJSON(["ok": true, "generation": generation, "files": files, "compileMs": compileMs,
               "linkMs": linkMs, "load": load, "refresh": refresh, "screenshot": image,
               "totalMs": milliseconds(since: start)])
}

/// Rewrites a frontend command from the build log so it compiles only
/// `primary` into `output`. Other primary files become plain inputs, and the
/// build's own output files are dropped.
func patchCommand(_ command: [String], primary: String, output: String) -> [String] {
    var result: [String] = []
    var index = 0
    while index < command.count {
        let argument = command[index]
        let value = index + 1 < command.count ? command[index + 1] : ""
        if argument == "-primary-file" {
            result += value == primary ? [argument, value] : [value]
            index += 2
        } else if argument == "-o" || argument == "-supplementary-output-file-map"
                    || argument == "-serialize-diagnostics-path" || argument == "-index-store-path"
                    || argument == "-index-unit-output-path"
                    || (argument.hasPrefix("-emit-") && argument.hasSuffix("-path")) {
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

/// The target and SDK flags from a frontend command, for linking the patch.
func linkSettings(_ command: [String]) -> [String] {
    var flags: [String] = []
    for flag in ["-target", "-sdk"] {
        if let index = command.firstIndex(of: flag), index + 1 < command.count {
            flags += [flag, command[index + 1]]
        }
    }
    return flags
}
