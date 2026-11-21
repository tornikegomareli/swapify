import Foundation

/// Recompiles the edited files, loads them into the running app, refreshes
/// SwiftUI, and returns what the screen shows now.
func reload(files: [String]) throws -> [String: Any] {
    let start = Date()
    var state = State.load()
    let generation = state.generation + 1
    // dlopen returns the already loaded image for a known path, so every
    // attempt, failed ones included, needs a new path.
    let attempt = "\(generation)-\(UUID().uuidString.prefix(8))"
    let directory = State.directory.appendingPathComponent("patches/\(attempt)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var timings: [String: Int] = [:]

    // Compile each file with its original command, as the only primary file.
    var objects: [String] = []
    var command: [String] = []
    for file in files {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        guard let original = state.commands[path] else {
            return ["ok": false, "stage": "compile", "file": path,
                    "error": "No compile command for this file. If it is new, run `hotreload build` and `hotreload launch`."]
        }
        command = original
        let object = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + ".o").path
        let result = try run(patchCommand(original, primary: path, output: object))
        guard result.status == 0 else {
            let errors = result.output.split(separator: "\n").filter { $0.contains("error:") }
            return ["ok": false, "stage": "compile", "file": path, "errors": errors.map(String.init)]
        }
        objects.append(object)
    }
    timings["compile"] = milliseconds(since: start)

    let dylib = directory.appendingPathComponent("patch_\(attempt).dylib").path
    let link = try run(linkCommand(command, objects: objects, output: dylib))
    guard link.status == 0 else { return ["ok": false, "stage": "link", "output": link.output] }
    timings["link"] = milliseconds(since: start) - timings["compile"]!

    let agent = AgentConnection()
    let load = try agent.send("load \(dylib)")
    guard load["ok"] as? Bool == true else {
        var report: [String: Any] = ["ok": false, "stage": "load", "agent": load]
        if load["needsRebuild"] as? Bool == true, let type = load["type"] as? String {
            report["needsRebuild"] = true
            report["type"] = try run(["xcrun", "swift-demangle", "--simplified", "--compact", type]).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "nominal type descriptor for ", with: "")
            report["reason"] = load["reason"]
            report["hint"] = "Stored properties or class methods changed. Run `hotreload build` and `hotreload launch`."
        }
        return report
    }
    state.generation = generation
    try state.save()
    let refresh = try agent.send("refresh")
    timings["loadAndRefresh"] = milliseconds(since: start) - timings["compile"]! - timings["link"]!

    let screenshot = try snapshot(agent, name: "reload-\(generation)")
    let visible = try visibleText(agent)
    timings["total"] = milliseconds(since: start)
    return ["ok": true, "generation": generation, "files": files, "ms": timings,
            "refreshedViews": refresh["hosts"] ?? 0, "screenshot": screenshot, "visibleText": visible]
}

/// Asks the agent to render the app into a PNG. Returns its path.
func snapshot(_ agent: AgentConnection, name: String) throws -> String {
    let directory = State.directory.appendingPathComponent("screens")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let reply = try agent.send("snapshot " + directory.appendingPathComponent(name + ".png").path)
    guard reply["ok"] as? Bool == true, let path = reply["path"] as? String else {
        throw CommandError(description: "Snapshot failed: \(reply)")
    }
    return path
}

/// Accessibility labels on screen, top to bottom, without repeats.
func visibleText(_ agent: AgentConnection) throws -> [String] {
    let elements = try agent.send("ui")["elements"] as? [[String: Any]] ?? []
    var seen = Set<String>()
    return elements.compactMap { $0["label"] as? String }.filter { !$0.isEmpty && seen.insert($0).inserted }
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

/// Links patch objects into a dylib with the clang next to swift-frontend.
/// App symbols stay undefined and bind to the running app at load time.
func linkCommand(_ command: [String], objects: [String], output: String) -> [String] {
    func value(_ flag: String) -> String {
        guard let index = command.firstIndex(of: flag), index + 1 < command.count else { return "" }
        return command[index + 1]
    }
    let toolchain = URL(fileURLWithPath: command[0]).deletingLastPathComponent().deletingLastPathComponent()
    let sdk = value("-sdk")
    return [toolchain.appendingPathComponent("bin/clang").path, "-target", value("-target"),
            "-isysroot", sdk, "-dynamiclib"] + objects
        + ["-o", output, "-undefined", "dynamic_lookup", "-Wl,-w",
           "-L\(sdk)/usr/lib/swift", "-L\(toolchain.path)/lib/swift/iphonesimulator"]
}
