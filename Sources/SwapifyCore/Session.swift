import Foundation
import Security

/// What swapify knows about one running app. Stored in `.swapify/session.json`
/// next to `swapify.json`.
public struct Session: Codable, Sendable {
    public var appPath: String?
    public var bundleID: String?
    public var udid: String?
    public var deviceSet: String?
    public var port: UInt16 = 0
    /// The device's name when the app runs on a device, nil on a simulator.
    public var deviceName: String?
    /// A device app: the SHA-1 of the certificate that signed it, which signs patches too.
    public var signingIdentity: String?
    /// A device app: the detached `devicectl` that holds its console and tunnel.
    public var consolePID: Int32?
    /// A device app: the CoreDevice tunnel address the agent is reached on.
    public var host: String?
    /// A device app: the token its agent asks for. A new random one per launch.
    public var token: String?
    public var generation = 0
    /// Source file path -> the swift-frontend command that compiled it.
    public var commands: [String: [String]] = [:]
    /// A file the build did not compile -> the compiled file whose command it borrows.
    public var borrowed: [String: String] = [:]
    /// Files reloaded since the last build, in the order of their first reload.
    public var changed: [String] = []

    public init() {}

    /// A random 128-bit token, as 32 hex digits.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Missing keys keep their defaults, so files from older versions load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        deviceSet = try container.decodeIfPresent(String.self, forKey: .deviceSet)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        signingIdentity = try container.decodeIfPresent(String.self, forKey: .signingIdentity)
        consolePID = try container.decodeIfPresent(Int32.self, forKey: .consolePID)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        commands = try container.decodeIfPresent([String: [String]].self, forKey: .commands) ?? [:]
        borrowed = try container.decodeIfPresent([String: String].self, forKey: .borrowed) ?? [:]
        changed = try container.decodeIfPresent([String].self, forKey: .changed) ?? []
    }
}

/// The project root: the directory with `swapify.json`, and `.swapify/` under it.
public struct Workspace: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = URL(fileURLWithPath: realPath(root.path), isDirectory: true)
    }

    /// The nearest directory at or above `path` that has a `swapify.json` or a
    /// `.swapify/` directory.
    public static func find(from path: URL) -> Workspace? {
        var directory = path.hasDirectoryPath ? path : path.deletingLastPathComponent()
        while true {
            let hasConfig = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(Configuration.fileName).path)
            let hasState = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".swapify/session.json").path)
            if hasConfig || hasState { return Workspace(root: directory) }
            if directory.path == "/" { return nil }
            directory.deleteLastPathComponent()
        }
    }

    public var stateDirectory: URL { root.appendingPathComponent(".swapify", isDirectory: true) }
    public var sessionFile: URL { stateDirectory.appendingPathComponent("session.json") }
    public var derivedData: URL { stateDirectory.appendingPathComponent("DerivedData", isDirectory: true) }
    public var buildLog: URL { stateDirectory.appendingPathComponent("build.log") }
    public var consoleLog: URL { stateDirectory.appendingPathComponent("console.log") }
    public var patches: URL { stateDirectory.appendingPathComponent("patches", isDirectory: true) }
    public var screens: URL { stateDirectory.appendingPathComponent("screens", isDirectory: true) }
    /// Device builds: each reloadable file as it was built, for the layout guard.
    public var originals: URL { stateDirectory.appendingPathComponent("originals", isDirectory: true) }
    /// Device builds: the symbols the app exports, which patches bind to.
    public var exports: URL { stateDirectory.appendingPathComponent("exports.txt") }

    public func loadSession() -> Session {
        guard let data = try? Data(contentsOf: sessionFile) else { return Session() }
        return (try? JSONDecoder().decode(Session.self, from: data)) ?? Session()
    }

    /// Writes the session readable by its owner only (mode 0600): it can hold a device token.
    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let temporary = sessionFile.path + ".\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: try encoder.encode(session),
                                             attributes: [.posixPermissions: 0o600]),
              rename(temporary, sessionFile.path) == 0
        else { throw SwapifyError("Cannot write \(sessionFile.path)") }
    }

    public func loadConfiguration() throws -> Configuration {
        try Configuration.load(from: root)
    }
}
