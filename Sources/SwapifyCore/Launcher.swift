import Foundation

public struct BuildReport: Codable, Sendable {
    public var app: String
    public var bundleID: String
    public var reloadableFiles: Int
    public var ms: Int
    /// New files that were reloaded but that this build did not compile.
    public var notInTarget: [String] = []

    /// The line for each file of `notInTarget`.
    public static func notInTargetMessages(_ files: [String]) -> [String] {
        files.map { "\(URL(fileURLWithPath: $0).lastPathComponent) is not in the target; add it in Xcode." }
    }
}

public struct LaunchReport: Codable, Sendable {
    public var udid: String
    public var bundleID: String
    public var port: UInt16
    public var console: String
    /// The device's name when the app runs on a device.
    public var device: String?
    /// On a device: whether a debugger is attached to the app.
    public var traced: Bool?
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

    /// Builds for the simulator, or for `device`.
    public func build(device: Device? = nil) throws -> BuildReport {
        let start = ContinuousClock.now
        let configuration = try workspace.loadConfiguration()
        var session = workspace.loadSession()
        try FileManager.default.createDirectory(at: workspace.stateDirectory, withIntermediateDirectories: true)

        let project = workspace.root.appendingPathComponent(configuration.project)
        let result = try Xcode.build(project: project, scheme: configuration.scheme,
                                     derivedData: workspace.derivedData, log: workspace.buildLog, device: device?.udid)
        let log = (try? String(contentsOf: workspace.buildLog, encoding: .utf8)) ?? ""
        guard result.succeeded else {
            if device != nil, let problem = Xcode.signingProblem(inBuildLog: log) { throw SwapifyError(problem) }
            let errors = Xcode.errors(inBuildLog: log)
                + BuildReport.notInTargetMessages(session.borrowed.keys.sorted().filter { FileManager.default.fileExists(atPath: $0) })
            throw SwapifyError("The build failed. Full log: \(workspace.buildLog.path)\n" + errors.joined(separator: "\n"))
        }

        // Commands are printed only for files that compiled in this build.
        let notInTarget = session.recordBuild(Xcode.frontendCommands(inBuildLog: log))
        guard !session.commands.isEmpty else {
            throw SwapifyError("The build was up to date, so no compile commands were captured. "
                               + "Delete \(workspace.derivedData.path) and build again.")
        }
        let app = try Xcode.builtApp(derivedData: workspace.derivedData, device: device != nil)
        if device != nil {
            try DevicePatches(workspace: workspace).prepare(app: app.path, files: Array(session.commands.keys))
        }
        session.appPath = app.path.path
        session.bundleID = app.bundleID
        try workspace.save(session)
        return BuildReport(app: app.path.path, bundleID: app.bundleID,
                           reloadableFiles: session.commands.count, ms: milliseconds(since: start), notInTarget: notInTarget)
    }

    /// Installs and launches the built app with the agent, then waits for its
    /// first screen. Without a device it uses the simulator of the last launch if it
    /// is still booted, then any booted simulator, and otherwise boots one.
    /// With `device`, it installs and launches the device build on that device instead.
    public func launch(udid: String? = nil, deviceSet: String? = nil, device: Device? = nil) throws -> LaunchReport {
        if let device { return try launch(on: device) }
        var session = workspace.loadSession()
        guard let appPath = session.appPath, let bundleID = session.bundleID else {
            throw SwapifyError("Nothing is built yet. Run `swapify run`.")
        }
        // The last run was on a device: stop its console, and forget the device.
        Self.stopConsole(session.consolePID)
        session.deviceName = nil
        session.host = nil
        session.token = nil
        session.signingIdentity = nil
        session.consolePID = nil
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
            report.warmup = try Reloader(workspace: workspace).reload(files: [file], snapshot: false, markChanged: false)
        }
        return report
    }

    /// Installs the device build, signs the agent with the app's identity, copies it
    /// into the app's `tmp/`, and launches the app with it and a new session token.
    private func launch(on device: Device) throws -> LaunchReport {
        var session = workspace.loadSession()
        guard let appPath = session.appPath, let bundleID = session.bundleID, appPath.contains("-iphoneos/") else {
            throw SwapifyError("Nothing is built for a device yet. Run `swapify run --device`.")
        }
        guard device.developerMode else { throw SwapifyError(Self.developerModeOff(device)) }
        guard try !device.isLocked() else { throw SwapifyError("\(device.name) is locked. Unlock it, then run again.") }
        Self.stopConsole(session.consolePID)

        let app = URL(fileURLWithPath: appPath)
        try device.install(app: app)
        let identity = try DevicePatches.signingIdentity(of: app)
        let agentPath = try device.copyToTemporaryDirectory(
            try DevicePatches(workspace: workspace).signedAgent(identity: identity), bundleID: bundleID)
        session.udid = device.udid
        session.deviceSet = nil
        session.deviceName = device.name
        session.signingIdentity = identity
        session.port = try Agent.freePort()
        session.token = Session.newToken()
        session.generation = 0
        session.consolePID = try device.launch(
            bundleID: bundleID,
            environment: ["DYLD_INSERT_LIBRARIES": agentPath, "SWAPIFY_PORT": String(session.port),
                          "SWAPIFY_TOKEN": session.token ?? ""],
            console: workspace.consoleLog)
        session.host = try device.tunnelAddress()
        try workspace.save(session)

        // Wait for this app's agent, then for the app to show a screen. A plain
        // connection: the device checks of Agent(session:) cost a second per try.
        let agent = Agent(port: session.port, host: session.host, token: session.token)
        let deadline = ContinuousClock.now + .seconds(40)
        var ping: AgentPing?
        while true {
            if let answer = try? agent.ping(), answer.bundleID == bundleID,
               let ui = try? agent.send("ui", as: AgentUI.self), !(ui.elements ?? []).isEmpty {
                guard (answer.protocol ?? 0) == agentProtocolVersion else {
                    throw SwapifyError("The agent speaks protocol \(answer.protocol ?? 0), this CLI \(agentProtocolVersion). Reinstall swapify.")
                }
                ping = answer
                break
            }
            let console = (try? String(contentsOf: workspace.consoleLog, encoding: .utf8)) ?? ""
            if let pid = session.consolePID, waitpid(pid, nil, WNOHANG) == pid {
                throw SwapifyError("The app did not start on \(device.name):\n" + console.suffix(1500))
            }
            guard ContinuousClock.now < deadline else {
                let locked = (try? device.isLocked()) == true
                throw SwapifyError(locked ? "\(device.name) locked while the app started. Unlock it, then run again."
                                   : "The app showed no screen within 40 s, or the agent did not start. See \(workspace.consoleLog.path)")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        var report = LaunchReport(udid: device.udid, bundleID: bundleID, port: session.port,
                                  console: workspace.consoleLog.path)
        report.device = device.name
        report.traced = ping?.traced
        if let file = session.commands.keys.sorted().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            report.warmup = try Reloader(workspace: workspace).reload(files: [file], snapshot: false, markChanged: false)
        }
        return report
    }

    public static func developerModeOff(_ device: Device) -> String {
        "Developer Mode is off on \(device.name). Turn it on in Settings > Privacy & Security > Developer Mode, "
            + "restart the phone, then run again."
    }

    /// Stops the `devicectl` that held the previous device app's console.
    static func stopConsole(_ pid: Int32?) {
        guard let pid, pid > 0,
              (try? Shell.run(["ps", "-p", String(pid), "-o", "command="]))?.output.contains("devicectl") == true
        else { return }
        kill(pid, SIGTERM)
    }
}
