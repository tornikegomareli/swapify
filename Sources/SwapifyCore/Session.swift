import Foundation

/// What swapify knows about one running app. Stored in `.swapify/session.json`
/// next to `swapify.json`.
public struct Session: Codable, Sendable {
    public var appPath: String?
    public var bundleID: String?
    public var udid: String?
    public var deviceSet: String?
    public var port: UInt16 = 0
    public var generation = 0
    /// Source file path -> the swift-frontend command that compiled it.
    public var commands: [String: [String]] = [:]

    public init() {}

    /// Missing keys keep their defaults, so files from older versions load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        deviceSet = try container.decodeIfPresent(String.self, forKey: .deviceSet)
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        commands = try container.decodeIfPresent([String: [String]].self, forKey: .commands) ?? [:]
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

    public func loadSession() -> Session {
        guard let data = try? Data(contentsOf: sessionFile) else { return Session() }
        return (try? JSONDecoder().decode(Session.self, from: data)) ?? Session()
    }

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: sessionFile, options: .atomic)
    }

    public func loadConfiguration() throws -> Configuration {
        try Configuration.load(from: root)
    }
}
