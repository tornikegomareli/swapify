import Foundation

/// Recompiles edited files, loads them into the running app, refreshes SwiftUI
/// and reports what the screen shows. See docs/architecture.md.
public struct Reloader: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Reloads `files`. The patch also compiles every other file changed since the
    /// build (see ChangedFiles.swift). Without `markChanged`, `files` do not join the
    /// changed set: the warm-up reload of an unchanged file.
    public func reload(files: [String], snapshot: Bool = true, markChanged: Bool = true) throws -> ReloadReport {
        let start = ContinuousClock.now
        var session = workspace.loadSession()
        let paths = files.map { URL(fileURLWithPath: $0, relativeTo: workspace.root).standardizedFileURL.path }
        var report = ReloadReport(status: .failed, files: paths)
        // A run that built for one platform and failed to launch leaves the app of
        // the other platform in the session. Its build commands do not fit that app.
        let builtForDevice = session.appPath?.contains("-iphoneos/") == true
        guard builtForDevice == (session.deviceName != nil) else {
            report.errors = ["The last build is for \(builtForDevice ? "a device" : "the simulator"), but it is not running. "
                             + "Run `swapify run\(builtForDevice ? " --device" : "")` again."]
            return report
        }
        if let problem = session.recordReload(of: paths, root: workspace.root.standardizedFileURL.path, markChanged: markChanged) {
            report.errors = [problem]
            return report
        }
        try workspace.save(session)
        let agent = Agent(workspace: workspace)

        // dlopen returns the image it already loaded for a known path, so every
        // attempt, failed ones too, gets a new directory.
        let generation = session.generation + 1
        let directory = workspace.patches.appendingPathComponent("\(generation)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = try patchSources(paths, session: session, directory: directory)
        report.compiled = sources.map(\.file)
        if session.deviceName != nil {
            return try reloadOnDevice(sources, session: session, agent: agent.keepingConnection(), directory: directory,
                                      report: report, snapshot: snapshot, start: start)
        }

        // Compile each file with its build command, as the only primary file, in parallel.
        let objects = sources.enumerated().map { index, source in
            directory.appendingPathComponent("\(index)-\(URL(fileURLWithPath: source.file).lastPathComponent).o").path
        }
        let results = try Shell.parallelMap(Array(zip(sources, objects))) { source, object in
            try Shell.run(FrontendCommand.patch(source.command, primary: source.file, output: object))
        }
        let failures = results.filter { !$0.succeeded }
        guard failures.isEmpty else {
            report.status = .compileError
            report.errors = Self.compileErrors(failures.map(\.output))
            return report
        }
        report.timings.compile = milliseconds(since: start)

        let dylib = directory.appendingPathComponent("patch.dylib").path
        let link = try Shell.run(FrontendCommand.link(sources[0].command, objects: objects, output: dylib))
        guard link.succeeded else {
            report.errors = ["Linking the patch failed:", link.output]
            return report
        }
        report.timings.link = milliseconds(since: start) - report.timings.compile
        let applied = try apply(dylib, agent: agent, report: report, generation: generation, snapshot: snapshot, start: start)
        guard applied.status == .needsRebuild, applied.changedType != nil else { return applied }
        return try reloadWithSideFields(sources, session: session, agent: agent, refused: applied,
                                        generation: generation, snapshot: snapshot, start: start)
    }

    /// A patch the agent refused for a layout change, built again with the new stored
    /// properties of classes in side storage (SideFields). Returns `refused` unchanged,
    /// or with a more precise reason, when the side route cannot keep objects valid either.
    private func reloadWithSideFields(_ sources: [PatchSource], session: Session, agent: Agent, refused: ReloadReport,
                                      generation: Int, snapshot: Bool, start: ContinuousClock.Instant) throws -> ReloadReport {
        var report = refused
        let sideStart = ContinuousClock.now
        let directory = workspace.patches.appendingPathComponent("\(generation)-side-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stems = sources.enumerated().map { index, source in
            directory.appendingPathComponent("\(index)-\(URL(fileURLWithPath: source.file).lastPathComponent)").path
        }
        let built = BuiltFiles(workspace: workspace)
        let files = try Shell.parallelMap(Array(zip(sources, stems))) { source, stem -> SideFields.File? in
            guard try Shell.run(FrontendCommand.patchIR(source.command, primary: source.file, output: stem + ".ll")).succeeded,
                  try Shell.run(FrontendCommand.patchSIL(source.command, primary: source.file, output: stem + ".sil")).succeeded
            else { return nil }
            return SideFields.File(original: source.isNew ? nil : try built.ir(of: source.file, command: source.command),
                                   ir: try String(contentsOfFile: stem + ".ll", encoding: .utf8),
                                   sil: try String(contentsOfFile: stem + ".sil", encoding: .utf8))
        }.compactMap { $0 }
        guard files.count == sources.count else { return refused }

        switch SideFields.rewrite(files) {
        case .refused(let type, let reason):
            if !type.isEmpty {  // a class the side route could not take: its reason is the precise one
                report.changedType = Self.demangle(type)
                report.reason = reason
            }
            return report
        case .rewritten(let texts, let types, let fields):
            let classes = types.map { Self.demangle($0).split(separator: ".").last.map(String.init) ?? $0 }
            if let name = SideFields.subclassElsewhere(of: classes, sources: Array(session.commands.keys),
                                                       patched: Set(sources.map(\.file))) {
                report.changedType = name
                report.reason = "a class in another file subclasses \(name)"
                return report
            }
            let objects = try Shell.parallelMap(Array(zip(texts, stems).enumerated())) { index, pair in
                let (text, stem) = pair
                try text.write(toFile: stem + ".side.ll", atomically: false, encoding: .utf8)
                return try Shell.run(FrontendCommand.compileIR(sources[index].command, ir: stem + ".side.ll", output: stem + ".o"))
            }
            if let failure = objects.first(where: { !$0.succeeded }) {
                report.status = .failed
                report.errors = ["Compiling the side-field patch failed:", failure.output]
                return report
            }
            report.timings.compile = milliseconds(since: sideStart)
            let dylib = directory.appendingPathComponent("patch.dylib").path
            let link = try Shell.run(FrontendCommand.link(sources[0].command, objects: stems.map { $0 + ".o" }, output: dylib))
            guard link.succeeded else {
                report.status = .failed
                report.errors = ["Linking the side-field patch failed:", link.output]
                return report
            }
            report.timings.link = milliseconds(since: sideStart) - report.timings.compile
            report.changedType = nil
            report.reason = nil
            report.errors = []
            report.sideFields = fields.isEmpty ? nil : fields.map { key in
                let dot = key.lastIndex(of: ".")!  // `$s…C.name`
                return Self.demangle(key[..<dot] + "Mn") + key[dot...]
            }
            var applied = try apply(dylib, agent: agent, report: report, generation: generation, snapshot: snapshot,
                                    start: start, sideTypes: types)
            if applied.status != .live { applied.sideFields = nil }  // another type changed too, such as a struct
            return applied
        }
    }

    /// The compiles of a patch for `paths`: every file changed since the build, each
    /// with the command that compiles it and the new files of its module as inputs.
    func patchSources(_ paths: [String], session: Session, directory: URL) throws -> [PatchSource] {
        try session.filesToCompile(for: paths).enumerated().map { index, file in
            guard let (command, inputs) = session.patchCommand(for: file) else {
                throw SwapifyError("\(file) has no compile command. Run `swapify run\(session.deviceName == nil ? "" : " --device")`.")
            }
            let list = directory.appendingPathComponent("\(index).SwiftFileList")
            return PatchSource(file: file, command: try FrontendCommand.adding(inputs, to: command, list: list),
                               isNew: session.commands[file] == nil)
        }
    }

    /// The error lines of failed compiles, without repeats, or their whole output.
    static func compileErrors(_ outputs: [String]) -> [String] {
        var seen = Set<String>()
        let errors = outputs.flatMap { $0.split(separator: "\n").filter { $0.contains("error:") }.map(String.init) }
            .filter { seen.insert($0).inserted }
        return errors.isEmpty ? outputs : errors
    }

    /// A device patch: built and signed on the Mac (DevicePatches), then sent to the
    /// app, which cannot read the Mac's files.
    private func reloadOnDevice(_ sources: [PatchSource], session: Session, agent: Agent, directory: URL,
                                report: ReloadReport, snapshot: Bool, start: ContinuousClock.Instant) throws -> ReloadReport {
        var report = report
        report.rebuildCommand = "swapify run --device"
        switch try DevicePatches(workspace: workspace).build(sources: sources, session: session, directory: directory) {
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
    /// With `sideTypes`, the agent's layout guard skips those classes: SideFields kept their objects valid.
    private func apply(_ dylib: String, agent: Agent, report: ReloadReport, generation: Int, snapshot: Bool,
                       start: ContinuousClock.Instant, sideTypes: [String] = []) throws -> ReloadReport {
        var report = report
        var session = workspace.loadSession()
        let command = sideTypes.isEmpty ? "load \(dylib)" : "load-side \(sideTypes.joined(separator: ",")) \(dylib)"
        let load = try agent.send(command, as: AgentLoad.self)
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
