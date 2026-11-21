import Foundation

/// Everything the CLI remembers between calls. Lives in `.hotreload/` in the
/// current directory.
struct State: Codable {
    var appPath: String?
    var bundleID: String?
    var udid: String?
    var deviceSet: String?
    var generation = 0
    /// Source file path -> the swift-frontend command that compiled it.
    var commands: [String: [String]] = [:]

    static let directory = URL(fileURLWithPath: ".hotreload", isDirectory: true).standardizedFileURL
    static let file = directory.appendingPathComponent("state.json")
    static let agentPort: UInt16 = 8899

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
