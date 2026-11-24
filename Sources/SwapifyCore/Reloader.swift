import Foundation

/// Recompiles edited files, loads them into the running app, refreshes SwiftUI
/// and reports what the screen shows. See docs/architecture.md.
public struct Reloader: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public func reload(files: [String], snapshot: Bool = true) throws -> ReloadReport {
        let start = ContinuousClock.now
        let session = workspace.loadSession()
        let paths = files.map { URL(fileURLWithPath: $0, relativeTo: workspace.root).standardizedFileURL.path }
        var report = ReloadReport(status: .failed, files: paths)
        let agent = Agent(workspace: workspace)

        // dlopen returns the image it already loaded for a known path, so every
        // attempt, failed ones too, gets a new directory.
        let generation = session.generation + 1
        let directory = workspace.patches.appendingPathComponent("\(generation)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if session.deviceName != nil {
            return try reloadOnDevice(paths, session: session, agent: agent.keepingConnection(), directory: directory, report: report,
                                      snapshot: snapshot, start: start)
        }

        // Compile each file with its build command, as the only primary file.
        var objects: [String] = []
        var command: [String] = []
        for path in paths {
            guard let original = session.commands[path] else {
                report.errors = ["\(path) has no compile command. New files need `swapify run`."]
                return report
            }
            command = original
            let object = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + ".o").path
            let result = try Shell.run(FrontendCommand.patch(original, primary: path, output: object))
            guard result.succeeded else {
                report.status = .compileError
                report.errors = result.output.split(separator: "\n").filter { $0.contains("error:") }.map(String.init)
                if report.errors.isEmpty { report.errors = [result.output] }
                return report
            }
            objects.append(object)
        }
        report.timings.compile = milliseconds(since: start)

        let dylib = directory.appendingPathComponent("patch.dylib").path
        let link = try Shell.run(FrontendCommand.link(command, objects: objects, output: dylib))
        guard link.succeeded else {
            report.errors = ["Linking the patch failed:", link.output]
            return report
        }
        report.timings.link = milliseconds(since: start) - report.timings.compile
        return try apply(dylib, agent: agent, report: report, generation: generation, snapshot: snapshot, start: start)
    }

    /// A device patch: built and signed on the Mac (DevicePatches), then sent to the
    /// app, which cannot read the Mac's files.
    private func reloadOnDevice(_ paths: [String], session: Session, agent: Agent, directory: URL, report: ReloadReport,
                                snapshot: Bool, start: ContinuousClock.Instant) throws -> ReloadReport {
        var report = report
        report.rebuildCommand = "swapify run --device"
        for path in paths where session.commands[path] == nil {
            report.errors = ["\(path) has no compile command. New files need `swapify run --device`."]
            return report
        }
        switch try DevicePatches(workspace: workspace).build(files: paths, session: session, directory: directory) {
        case .compileError(let errors):
            report.status = .compileError
            report.errors = errors
            return report
        case .layoutChanged(let type, let reason):
            report.status = .needsRebuild
            report.changedType = Self.demangle(type)
            report.reason = reason
            report.errors = ["layout changed"]
            return report
        case .built(let dylib, let compile, let link, let warnings):
            report.timings.compile = compile
            report.timings.link = link
            let sent = ContinuousClock.now
            let bytes = try Data(contentsOf: dylib)
            let put = try agent.send("put \(directory.lastPathComponent).dylib \(bytes.count)", payload: bytes, as: AgentPut.self)
            guard put.ok, let path = put.path else {
                report.errors = [put.error ?? "The app did not take the patch."]
                return report
            }
            report.timings.transfer = milliseconds(since: sent)
            var applied = try apply(path, agent: agent, report: report, generation: session.generation + 1,
                                    snapshot: snapshot, start: start)
            applied.errors += warnings
            return applied
        }
    }

    /// Loads the patch at `dylib` (a path the app can read), refreshes SwiftUI, and
    /// reads the screen.
    private func apply(_ dylib: String, agent: Agent, report: ReloadReport, generation: Int, snapshot: Bool,
                       start: ContinuousClock.Instant) throws -> ReloadReport {
        var report = report
        var session = workspace.loadSession()
        let load = try agent.send("load \(dylib)", as: AgentLoad.self)
        guard load.ok else {
            if load.needsRebuild == true {
                report.status = .needsRebuild
                report.changedType = load.type.map(Self.demangle)
                report.reason = load.reason
            }
            report.errors = [load.error ?? "The agent rejected the patch."]
            return report
        }
        session.generation = load.generation ?? generation
        try workspace.save(session)
        report.generation = session.generation
        report.timings.patch = Int((load.dlopenMs ?? 0) + (load.patchMs ?? 0))

        let refresh = try agent.send("refresh", as: AgentRefresh.self)
        report.timings.refresh = Int(refresh.ms ?? 0)
        report.status = .live
        if !refresh.ok { report.errors = [refresh.error ?? "SwiftUI refresh failed."] }

        if snapshot {
            report.screenshot = try? capture(agent, name: "reload-\(session.generation)")
            report.visibleText = try? visibleText(agent)
        }
        report.timings.total = milliseconds(since: start)
        return report
    }

    /// Renders the app into a PNG inside the agent and returns its path. A device app
    /// sends the PNG back, and the CLI writes it.
    public func capture(_ agent: Agent, name: String) throws -> String {
        try FileManager.default.createDirectory(at: workspace.screens, withIntermediateDirectories: true)
        let path = workspace.screens.appendingPathComponent(name + ".png").path
        if agent.device != nil {
            let reply = try agent.send("snapshot", as: AgentSnapshot.self)
            guard reply.ok, let png = reply.png.flatMap({ Data(base64Encoded: $0) }) else {
                throw SwapifyError(reply.error.map { $0 == "no visible window" ? "The app is not on screen." : $0 }
                                   ?? "Snapshot failed")
            }
            try png.write(to: URL(fileURLWithPath: path))
            return path
        }
        let reply = try agent.send("snapshot \(path)", as: AgentSnapshot.self)
        guard reply.ok, let written = reply.path else { throw SwapifyError(reply.error ?? "Snapshot failed") }
        return written
    }

    /// Accessibility labels on screen, top to bottom, without repeats.
    public func visibleText(_ agent: Agent) throws -> [String] {
        var seen = Set<String>()
        return (try agent.send("ui", as: AgentUI.self).elements ?? [])
            .map(\.label).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func demangle(_ symbol: String) -> String {
        let output = (try? Shell.run(["xcrun", "swift-demangle", "--simplified", "--compact", symbol]).output) ?? symbol
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "nominal type descriptor for ", with: "")
    }
}
