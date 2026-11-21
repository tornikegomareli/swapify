import Foundation

/// Installs the app and launches it with the agent inserted.
func launchApp(udid: String?, deviceSet: String?) throws {
    var state = State.load()
    guard let appPath = state.appPath, let bundleID = state.bundleID else {
        throw CommandError(description: "Run `hotreload build` first")
    }
    state.deviceSet = deviceSet
    state.udid = try udid ?? bootedDevice(state)
    guard let device = state.udid else { throw CommandError(description: "No booted simulator") }

    try check(run(state.simctl + ["install", device, appPath]))
    let console = State.directory.appendingPathComponent("console.log").path
    let agent = State.directory.appendingPathComponent("HotAgent.dylib").path
    try check(run(state.simctl + ["launch", "--terminate-running-process",
                                  "--stdout=\(console)", "--stderr=\(console)", device, bundleID],
                  environment: ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": agent]))
    state.generation = 0
    try state.save()

    // Wait until the app shows its first screen.
    let start = Date()
    while ((try? AgentConnection().send("ui"))?["elements"] as? [Any] ?? []).isEmpty {
        guard Date().timeIntervalSince(start) < 15 else {
            throw CommandError(description: "The app shows no UI, or the agent did not answer. See \(console)")
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    // Warm-up: reload one unchanged file. The first patch in a process pays a
    // one-time dlopen cost, and this also checks the whole pipeline.
    var report: [String: Any] = ["ok": true, "udid": device, "bundleID": bundleID, "console": console]
    if let file = state.commands.keys.sorted().first(where: { FileManager.default.fileExists(atPath: $0) }) {
        let warmup = try reload(files: [file])
        report["warmup"] = warmup["ok"] as? Bool == true
            ? ["ok": true, "file": file, "ms": (warmup["ms"] as? [String: Int])?["total"] ?? 0]
            : warmup
    }
    printJSON(report)
}

func bootedDevice(_ state: State) throws -> String? {
    let output = try run(state.simctl + ["list", "devices", "booted", "-j"]).output
    let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    let runtimes = json?["devices"] as? [String: [[String: Any]]] ?? [:]
    return runtimes.values.flatMap { $0 }.first { $0["state"] as? String == "Booted" }?["udid"] as? String
}

func screenshot(_ state: State, name: String) throws -> String {
    guard let device = state.udid else { throw CommandError(description: "Run `hotreload launch` first") }
    let directory = State.directory.appendingPathComponent("screens")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("\(name).png").path
    try check(run(state.simctl + ["io", device, "screenshot", path]))
    return path
}

func check(_ result: ProcessResult) throws {
    guard result.status == 0 else { throw CommandError(description: result.output) }
}
