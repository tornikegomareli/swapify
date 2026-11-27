import Foundation

public enum SwapifyInfo {
    public static let version = "0.1.3"
}

/// What `swapify init` writes into a project.
public struct Setup: Sendable {
    public struct Change: Codable, Sendable, Equatable {
        public enum Action: String, Codable, Sendable { case created, updated, unchanged }
        public var file: String
        public var action: Action
    }

    public let root: URL
    /// The command that runs swapify, written into agent configuration files.
    public let command: String

    public init(root: URL, command: String) {
        self.root = root
        self.command = command
    }

    /// The only Xcode workspace or project in the root, or `explicit`.
    public func project(_ explicit: String?) throws -> String {
        if let explicit {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(explicit).path) else {
                throw SwapifyError("\(explicit) does not exist in \(root.path)")
            }
            return explicit
        }
        let candidates = Xcode.projects(in: root)
        guard let first = candidates.first else {
            throw SwapifyError("No .xcworkspace or .xcodeproj in \(root.path). Run swapify init in the project directory.")
        }
        // A workspace and its own project are one choice: the workspace.
        let workspaces = candidates.filter { $0.hasSuffix(".xcworkspace") }
        if workspaces.count == 1 || candidates.count == 1 { return workspaces.first ?? first }
        throw SwapifyError("Several projects found: \(candidates.joined(separator: ", ")). Pass --project.")
    }

    public func scheme(project: String, _ explicit: String?) throws -> String {
        let schemes = try Xcode.schemes(project: root.appendingPathComponent(project))
        if let explicit {
            guard schemes.contains(explicit) else {
                throw SwapifyError("No scheme \(explicit). Schemes: \(schemes.joined(separator: ", "))")
            }
            return explicit
        }
        let apps = schemes.filter { !$0.hasSuffix("Tests") }
        if apps.count == 1 { return apps[0] }
        throw SwapifyError("Pick the app scheme with --scheme. Schemes: \(schemes.joined(separator: ", "))")
    }

    public func writeConfiguration(_ configuration: Configuration) throws -> Change {
        let existing = try? Configuration.load(from: root)
        if existing == configuration { return Change(file: Configuration.fileName, action: .unchanged) }
        try configuration.save(to: root)
        return Change(file: Configuration.fileName, action: existing == nil ? .created : .updated)
    }

    /// Adds `.swapify/` to `.gitignore` in a git repository.
    public func ignoreStateDirectory() throws -> Change? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        let file = root.appendingPathComponent(".gitignore")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(".swapify/") || lines.contains(".swapify") { return Change(file: ".gitignore", action: .unchanged) }
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        try (text + separator + ".swapify/\n").write(to: file, atomically: true, encoding: .utf8)
        return Change(file: ".gitignore", action: text.isEmpty ? .created : .updated)
    }

    /// Adds the PostToolUse hook to `.claude/settings.json`, keeping every
    /// other setting.
    public func installClaudeHook() throws -> Change {
        let path = ".claude/settings.json"
        var settings = try readJSONObject(path)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var postToolUse = hooks["PostToolUse"] as? [[String: Any]] ?? []
        let installed = postToolUse.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("swapify") == true }
        }
        if installed { return Change(file: path, action: .unchanged) }
        postToolUse.append([
            "matcher": "Edit|Write|MultiEdit",
            "hooks": [["type": "command", "command": "\(quoted(command)) hook", "timeout": 120]],
        ])
        hooks["PostToolUse"] = postToolUse
        settings["hooks"] = hooks
        return try writeJSONObject(settings, to: path)
    }

    /// Registers the MCP server in `.mcp.json`, which Claude Code and other
    /// agents read for project servers.
    public func installMCPServer() throws -> Change {
        let path = ".mcp.json"
        var config = try readJSONObject(path)
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        if servers["swapify"] != nil { return Change(file: path, action: .unchanged) }
        servers["swapify"] = ["command": command, "args": ["mcp"]]
        config["mcpServers"] = servers
        return try writeJSONObject(config, to: path)
    }

    public func installSkill(_ text: String) throws -> Change {
        let path = ".claude/skills/swapify/SKILL.md"
        let file = root.appendingPathComponent(path)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        if existing == text { return Change(file: path, action: .unchanged) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return Change(file: path, action: existing == nil ? .created : .updated)
    }

    private func readJSONObject(_ path: String) throws -> [String: Any] {
        let file = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: file) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SwapifyError("\(file.path) is not a JSON object. Fix it and run swapify init again.")
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to path: String) throws -> Change {
        let file = root.appendingPathComponent(path)
        let wasThere = FileManager.default.fileExists(atPath: file.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
        return Change(file: path, action: wasThere ? .updated : .created)
    }

    private func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
