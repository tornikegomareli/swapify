import Foundation

/// Environment checks for `swapify doctor` and the MCP `status` tool.
public struct Doctor: Sendable {
    public struct Check: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case ok, warning, failure }
        public var name: String
        public var status: Status
        public var detail: String
    }

    public let workspace: Workspace?

    public init(workspace: Workspace?) {
        self.workspace = workspace
    }

    public func run() -> [Check] {
        var checks = [mac(), xcode(), agentDylib()]
        guard let workspace else {
            checks.append(Check(name: "Project", status: .failure,
                                detail: "No swapify.json here or above. Run `swapify init` in the project directory."))
            return checks
        }
        checks.append(configuration(workspace))
        let session = workspace.loadSession()
        checks.append(build(session))
        checks.append(session.deviceName == nil ? simulator(session) : device(session))
        checks.append(agent(workspace))
        return checks
    }

    private func mac() -> Check {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine == "arm64"
            ? Check(name: "Mac", status: .ok, detail: "Apple silicon")
            : Check(name: "Mac", status: .failure, detail: "swapify needs an Apple silicon Mac; this one is \(machine).")
    }

    private func xcode() -> Check {
        guard let result = try? Shell.run(["xcodebuild", "-version"]), result.succeeded else {
            return Check(name: "Xcode", status: .failure, detail: "xcodebuild not found. Install Xcode and run xcode-select.")
        }
        let version = result.output.split(separator: "\n").joined(separator: ", ")
        return Check(name: "Xcode", status: .ok, detail: version)
    }

    private func agentDylib() -> Check {
        do {
            let url = try Resources.agent()
            _ = try Resources.agent(device: true)
            return Check(name: "Agent", status: .ok, detail: url.deletingLastPathComponent().path + " (simulator and device)")
        } catch {
            return Check(name: "Agent", status: .failure, detail: "\(error)")
        }
    }

    private func configuration(_ workspace: Workspace) -> Check {
        do {
            let configuration = try workspace.loadConfiguration()
            let exists = FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(configuration.project).path)
            return exists
                ? Check(name: "Project", status: .ok, detail: "\(configuration.project), scheme \(configuration.scheme)")
                : Check(name: "Project", status: .failure, detail: "\(configuration.project) does not exist")
        } catch {
            return Check(name: "Project", status: .failure, detail: "\(error)")
        }
    }

    private func build(_ session: Session) -> Check {
        guard let app = session.appPath, FileManager.default.fileExists(atPath: app) else {
            return Check(name: "Build", status: .warning, detail: "Not built yet. Run `swapify run`.")
        }
        return Check(name: "Build", status: .ok,
                     detail: "\(URL(fileURLWithPath: app).lastPathComponent), \(session.commands.count) reloadable Swift files")
    }

    private func simulator(_ session: Session) -> Check {
        let simulator = Simulator(deviceSet: session.deviceSet)
        guard let booted = try? simulator.bootedDevice(preferring: session.udid) else {
            return Check(name: "Simulator", status: .warning, detail: "None booted. `swapify run` boots one.")
        }
        return Check(name: "Simulator", status: .ok, detail: "Booted: \(booted)")
    }

    /// The iPhone of the last `swapify run --device`: connected, Developer Mode, unlocked.
    private func device(_ session: Session) -> Check {
        guard let name = session.deviceName, let udid = session.udid else {
            return Check(name: "iPhone", status: .warning, detail: "None yet.")
        }
        guard let device = try? Device.connected().first(where: { $0.udid == udid }) else {
            return Check(name: "iPhone", status: .failure, detail: "\(name) is not connected. Connect it by cable or on the same Wi-Fi.")
        }
        if !device.developerMode {
            return Check(name: "iPhone", status: .failure, detail: Launcher.developerModeOff(device))
        }
        if (try? device.isLocked()) == true {
            return Check(name: "iPhone", status: .warning, detail: "\(name) is locked, so the app is suspended. Unlock it.")
        }
        return Check(name: "iPhone", status: .ok, detail: "\(name), connected, Developer Mode on, unlocked")
    }

    private func agent(_ workspace: Workspace) -> Check {
        let session = workspace.loadSession()
        guard session.port != 0 else {
            return Check(name: "App", status: .warning, detail: "Not launched with swapify yet.")
        }
        let ping: AgentPing
        do {
            ping = try Agent(workspace: workspace).ping()
        } catch {
            return Check(name: "App", status: .warning, detail: session.deviceName == nil
                         ? "Not answering on port \(session.port). It is closed, suspended, or crashed." : "\(error)")
        }
        if ping.protocol != agentProtocolVersion {
            return Check(name: "App", status: .failure,
                         detail: "Agent protocol \(ping.protocol ?? 0), CLI protocol \(agentProtocolVersion). Run `swapify run`.")
        }
        if ping.swiftUIRefresh != true {
            return Check(name: "App", status: .warning,
                         detail: "\(ping.bundleID) runs, but this iOS version lacks the SwiftUI refresh symbols. Reloads apply; views redraw on their next update.")
        }
        let debugger = ping.traced.map { $0 ? ", a debugger is attached" : ", no debugger" } ?? ""
        return Check(name: "App", status: .ok, detail: "\(ping.bundleID), generation \(ping.generation)\(debugger)")
    }
}
