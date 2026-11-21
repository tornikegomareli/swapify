import Foundation

/// Everything the CLI remembers between calls. Lives in `.hotreload/` in the
/// current directory.
struct State: Codable {
    var appPath: String?
    var bundleID: String?
    var udid: String?
    var deviceSet: String?
    var generation = 0
    /// The agent's port. Each launch picks a free one, so apps don't collide.
    var port: UInt16 = 0
    /// Source file path -> the swift-frontend command that compiled it.
    var commands: [String: [String]] = [:]

    // A real path: simctl does not map /tmp to /private/tmp the way the host
    // does, and URL.resolvingSymlinksInPath() strips /private on purpose.
    static let directory: URL = {
        let cwd = FileManager.default.currentDirectoryPath
        let real = realpath(cwd, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }
        return URL(fileURLWithPath: real ?? cwd, isDirectory: true).appendingPathComponent(".hotreload")
    }()
    static let file = directory.appendingPathComponent("state.json")

    init() {}

    /// Missing keys keep their defaults, so state files from older versions load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        deviceSet = try container.decodeIfPresent(String.self, forKey: .deviceSet)
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 0
        commands = try container.decodeIfPresent([String: [String]].self, forKey: .commands) ?? [:]
    }

    static func load() -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: State.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: State.file)
    }

    var simctl: [String] {
        ["xcrun", "simctl"] + (deviceSet.map { ["--set", $0] } ?? [])
    }
}
