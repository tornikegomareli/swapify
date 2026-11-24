import Foundation

/// A connected iPhone or iPad, through `xcrun devicectl`. Every call reads
/// devicectl's JSON output.
public struct Device: Sendable, Equatable {
    public var udid: String
    public var name: String
    /// Developer Mode is on (Settings > Privacy & Security > Developer Mode).
    public var developerMode: Bool

    public init(udid: String, name: String, developerMode: Bool) {
        self.udid = udid
        self.name = name
        self.developerMode = developerMode
    }

    /// Paired iOS devices that are connected now, by cable or on the network.
    public static func connected() throws -> [Device] {
        let result = try devicectl(["list", "devices"])
        return (result["devices"] as? [[String: Any]] ?? []).compactMap { device in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["reality"] as? String == "physical", hardware["platform"] as? String == "iOS",
                  connection["pairingState"] as? String == "paired", connection["transportType"] != nil,
                  let udid = hardware["udid"] as? String
            else { return nil }
            return Device(udid: udid, name: properties["name"] as? String ?? udid,
                          developerMode: properties["developerModeStatus"] as? String == "enabled")
        }
    }

    /// The device that `query` (a name or UDID) picks, or the only connected one.
    public static func choose(_ devices: [Device], query: String?) throws -> Device {
        if let query {
            guard let device = devices.first(where: { $0.udid == query || $0.name == query })
                ?? devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) })
            else {
                throw SwapifyError("No connected device is named \(query). Connected: \(list(devices)).")
            }
            return device
        }
        guard !devices.isEmpty else {
            throw SwapifyError("No iPhone is connected. Connect one with a cable, or on the same Wi-Fi, "
                               + "and pair it in Xcode (Window > Devices and Simulators).")
        }
        guard devices.count == 1 else {
            throw SwapifyError("\(devices.count) devices are connected: \(list(devices)). "
                               + "Pick one with `swapify run --device --udid <name or UDID>`.")
        }
        return devices[0]
    }

    private static func list(_ devices: [Device]) -> String {
        devices.isEmpty ? "none" : devices.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
    }

    /// A passcode is needed to unlock it. Apps cannot launch, and a running app is suspended.
    public func isLocked() throws -> Bool {
        try Self.devicectl(["device", "info", "lockState", "--device", udid])["passcodeRequired"] as? Bool ?? false
    }

    /// The device's address in the CoreDevice tunnel, an encrypted link over the
    /// cable or the network. Reading it brings the tunnel up.
    public func tunnelAddress() throws -> String {
        let details = try Self.devicectl(["device", "info", "details", "--device", udid])
        guard let address = (details["connectionProperties"] as? [String: Any])?["tunnelIPAddress"] as? String else {
            throw SwapifyError("\(name) has no CoreDevice tunnel. Reconnect it, or open Xcode > Devices and Simulators.")
        }
        return address
    }

    public func install(app: URL) throws {
        _ = try Self.devicectl(["device", "install", "app", "--device", udid, app.path])
    }

    /// Copies a file into the app's `tmp/` and returns its path on the device.
    public func copyToTemporaryDirectory(_ file: URL, bundleID: String) throws -> String {
        let result = try Self.devicectl(["device", "copy", "to", "--device", udid, "--source", file.path,
                                    "--destination", "tmp/" + file.lastPathComponent, "--domain-type",
                                    "appDataContainer", "--domain-identifier", bundleID])
        guard let destination = result["destination"] as? String, let url = URL(string: destination) else {
            throw SwapifyError("devicectl copied \(file.lastPathComponent) but did not say where.")
        }
        return url.path
    }

    /// Launches the app with `environment`, replacing a running copy, and keeps
    /// `devicectl` attached to its console in a session of its own. That process
    /// holds the CoreDevice tunnel open, which closes within seconds without a
    /// client, and writes the app's output to `console`. It ends with the app.
    public func launch(bundleID: String, environment: [String: String], console: URL) throws -> pid_t {
        // DEVICECTL_CHILD_ variables reach the app without appearing in a command line.
        let variables = Dictionary(uniqueKeysWithValues: environment.map { ("DEVICECTL_CHILD_" + $0, $1) })
        return try Shell.spawnDetached(["xcrun", "devicectl", "device", "process", "launch", "--device", udid,
                                        "--console", "--terminate-existing", bundleID],
                                       environment: variables, log: console)
    }

    /// A full-screen capture, including the status bar and system alerts, of the
    /// display that is on. devicectl's default is the primary display, which on a
    /// phone with two displays can be the dark one.
    public func screenshot(to path: URL) throws {
        let displays = try Self.devicectl(["device", "info", "displays", "--device", udid])["displays"] as? [[String: Any]]
        let active = displays?.first { $0["active"] as? Bool == true }?["uniqueId"] as? String
        _ = try Self.devicectl(["device", "capture", "screenshot", "--device", udid, "--destination", path.path]
                               + (active.map { ["--display-unique-id", $0] } ?? []))
    }

    /// Runs devicectl with JSON output and returns its `result` object.
    @discardableResult
    static func devicectl(_ arguments: [String]) throws -> [String: Any] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("swapify-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let run = try Shell.run(["xcrun", "devicectl"] + arguments + ["--json-output", output.path, "-q"])
        guard run.succeeded else {
            throw SwapifyError("devicectl \(arguments.prefix(3).joined(separator: " ")) failed:\n"
                               + run.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let json = (try? Data(contentsOf: output)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return json?["result"] as? [String: Any] ?? [:]
    }
}
