import Foundation

public struct BuildReport: Codable, Sendable {
    public var app: String
    public var bundleID: String
    public var reloadableFiles: Int
    public var ms: Int
}

public struct LaunchReport: Codable, Sendable {
    public var udid: String
    public var bundleID: String
    public var port: UInt16
    public var console: String
    /// The first reload of a process pays a one-time dlopen cost. Launch pays
    /// it by reloading one unchanged file, which also checks the pipeline.
    public var warmup: ReloadReport?
}

/// Builds the app with reload settings, and launches it with the agent.
public struct Launcher: Sendable {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public func build() throws -> BuildReport {
        let start = ContinuousClock.now
        let configuration = try workspace.loadConfiguration()
        var session = workspace.loadSession()
        try FileManager.default.createDirectory(at: workspace.stateDirectory, withIntermediateDirectories: true)

        let project = workspace.root.appendingPathComponent(configuration.project)
        let result = try Xcode.build(project: project, scheme: configuration.scheme,
                                     derivedData: workspace.derivedData, log: workspace.buildLog)
        let log = (try? String(contentsOf: workspace.buildLog, encoding: .utf8)) ?? ""
        guard result.succeeded else {
            let errors = Xcode.errors(inBuildLog: log)
            throw SwapifyError("The build failed. Full log: \(workspace.buildLog.path)\n" + errors.joined(separator: "\n"))
        }

        // Commands are printed only for files that compiled in this build.
        session.commands.merge(Xcode.frontendCommands(inBuildLog: log)) { $1 }
        guard !session.commands.isEmpty else {
            throw SwapifyError("The build was up to date, so no compile commands were captured. "
                               + "Delete \(workspace.derivedData.path) and build again.")
        }
        let app = try Xcode.builtApp(derivedData: workspace.derivedData)
        session.appPath = app.path.path
        session.bundleID = app.bundleID
        try workspace.save(session)
        return BuildReport(app: app.path.path, bundleID: app.bundleID,
                           reloadableFiles: session.commands.count, ms: milliseconds(since: start))
    }

    /// Installs and launches the built app with the agent, then waits for its
    /// first screen. Without a device it uses the simulator of the last launch if it
    /// is still booted, then any booted simulator, and otherwise boots one.
    public func launch(udid: String? = nil, deviceSet: String? = nil) throws -> LaunchReport {
        var session = workspace.loadSession()
        guard let appPath = session.appPath, let bundleID = session.bundleID else {
            throw SwapifyError("Nothing is built yet. Run `swapify run`.")
        }
        let simulator = Simulator(deviceSet: deviceSet)
        let previous = deviceSet == session.deviceSet ? session.udid : nil
        let device = try udid ?? simulator.bootedDevice(preferring: previous) ?? simulator.bootNewestiPhone()
        let agentDylib = try Resources.agent()

        try simulator.install(app: URL(fileURLWithPath: appPath), on: device)
        session.udid = device
        session.deviceSet = deviceSet
        session.port = try Agent.freePort()
        session.generation = 0
        try workspace.save(session)
        try simulator.launch(bundleID: bundleID, on: device, agent: agentDylib, port: session.port,
                             console: workspace.consoleLog)

        // Wait for this app's agent, then for the first screen.
        let agent = Agent(port: session.port)
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            if let ping = try? agent.ping(), ping.bundleID == bundleID,
               let ui = try? agent.send("ui", as: AgentUI.self), !(ui.elements ?? []).isEmpty {
                guard (ping.protocol ?? 0) == agentProtocolVersion else {
                    throw SwapifyError("The agent speaks protocol \(ping.protocol ?? 0), this CLI \(agentProtocolVersion). Reinstall swapify.")
                }
                break
            }
            guard ContinuousClock.now < deadline else {
                throw SwapifyError("The app showed no UI within 20 s, or the agent did not start. See \(workspace.consoleLog.path)")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        var report = LaunchReport(udid: device, bundleID: bundleID, port: session.port,
                                  console: workspace.consoleLog.path)
        if let file = session.commands.keys.sorted().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            report.warmup = try Reloader(workspace: workspace).reload(files: [file], snapshot: false)
        }
        return report
    }
}
