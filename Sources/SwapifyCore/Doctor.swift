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
        checks.append(simulator(session))
        checks.append(agent(session))
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
            return Check(name: "Agent", status: .ok, detail: url.path)
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

    private func agent(_ session: Session) -> Check {
        guard session.port != 0 else {
            return Check(name: "App", status: .warning, detail: "Not launched with swapify yet.")
        }
        guard let ping = try? Agent(port: session.port).ping() else {
            return Check(name: "App", status: .warning,
                         detail: "Not answering on port \(session.port). It is closed, suspended, or crashed.")
        }
        if ping.protocol != agentProtocolVersion {
            return Check(name: "App", status: .failure,
                         detail: "Agent protocol \(ping.protocol ?? 0), CLI protocol \(agentProtocolVersion). Run `swapify run`.")
        }
        if ping.swiftUIRefresh != true {
            return Check(name: "App", status: .warning,
                         detail: "\(ping.bundleID) runs, but this iOS version lacks the SwiftUI refresh symbols. Reloads apply; views redraw on their next update.")
        }
        return Check(name: "App", status: .ok, detail: "\(ping.bundleID), generation \(ping.generation)")
    }
}
