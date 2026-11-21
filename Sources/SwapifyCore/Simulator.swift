import Foundation

/// `xcrun simctl` for one device set. `deviceSet == nil` is the default set
/// that Simulator.app shows.
public struct Simulator: Sendable {
    public var deviceSet: String?

    public init(deviceSet: String? = nil) {
        self.deviceSet = deviceSet
    }

    private func simctl(_ arguments: [String]) -> [String] {
        ["xcrun", "simctl"] + (deviceSet.map { ["--set", $0] } ?? []) + arguments
    }

    private func check(_ result: ProcessResult, _ action: String) throws {
        guard result.succeeded else { throw SwapifyError("simctl \(action) failed:\n\(result.output)") }
    }

    private func devices(_ filter: String) throws -> [(runtime: String, device: [String: Any])] {
        let output = try Shell.run(simctl(["list", "devices", filter, "-j"])).output
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let byRuntime = json?["devices"] as? [String: [[String: Any]]] ?? [:]
        return byRuntime.flatMap { runtime, devices in devices.map { (runtime, $0) } }
    }

    /// A booted simulator: `preferred` if it is booted, otherwise the first by UDID.
    public func bootedDevice(preferring preferred: String? = nil) throws -> String? {
        let booted = try devices("booted").compactMap { entry in
            entry.device["state"] as? String == "Booted" ? entry.device["udid"] as? String : nil
        }
        return Self.choose(booted: booted, preferred: preferred)
    }

    /// `simctl` lists runtimes in no fixed order, so the choice must not depend on it.
    static func choose(booted: [String], preferred: String?) -> String? {
        if let preferred, booted.contains(preferred) { return preferred }
        return booted.sorted().first
    }

    /// Boots the newest available iPhone and shows it in Simulator.app.
    public func bootNewestiPhone() throws -> String {
        let iPhones = try devices("available").filter {
            $0.runtime.contains("iOS") && ($0.device["name"] as? String ?? "").hasPrefix("iPhone")
        }
        let newest = iPhones.max { a, b in
            a.runtime.compare(b.runtime, options: .numeric) == .orderedAscending
        }
        guard let udid = newest?.device["udid"] as? String else {
            throw SwapifyError("No iPhone simulator is available. Create one in Xcode > Settings > Components.")
        }
        try check(Shell.run(simctl(["boot", udid])), "boot")
        try check(Shell.run(simctl(["bootstatus", udid, "-b"])), "bootstatus")
        if deviceSet == nil { try Shell.run(["open", "-a", "Simulator"]) }
        return udid
    }

    public func install(app: URL, on udid: String) throws {
        try check(Shell.run(simctl(["install", udid, app.path])), "install")
    }

    /// Launches the app with the agent inserted. Terminates a running copy.
    public func launch(bundleID: String, on udid: String, agent: URL, port: UInt16, console: URL) throws {
        try check(Shell.run(
            simctl(["launch", "--terminate-running-process", "--stdout=\(console.path)",
                    "--stderr=\(console.path)", udid, bundleID]),
            environment: ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": agent.path,
                          "SIMCTL_CHILD_SWAPIFY_PORT": String(port)]), "launch")
    }

    /// A full-screen capture, including the status bar and system alerts.
    public func screenshot(on udid: String, to path: URL) throws {
        try check(Shell.run(simctl(["io", udid, "screenshot", path.path])), "io screenshot")
    }
}
