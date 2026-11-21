import Foundation
import Testing
@testable import SwapifyCore

@Suite struct SetupTests {
    let root: URL
    let setup: Setup

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swapify-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setup = Setup(root: root, command: "/opt/homebrew/bin/swapify")
    }

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func hookKeepsExistingSettingsAndInstallsOnce() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"model":"opus","hooks":{"Stop":[{"hooks":[]}]}}"#
            .write(to: root.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)

        #expect(try setup.installClaudeHook().action == .updated)
        #expect(try setup.installClaudeHook().action == .unchanged)

        let settings = try json(".claude/settings.json")
        #expect(settings["model"] as? String == "opus")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks["Stop"] != nil)
        let postToolUse = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(postToolUse.count == 1)
        #expect(postToolUse[0]["matcher"] as? String == "Edit|Write|MultiEdit")
        let command = (postToolUse[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
        #expect(command == "/opt/homebrew/bin/swapify hook")
    }

    @Test func mcpServerIsAddedNextToOtherServers() throws {
        try #"{"mcpServers":{"other":{"command":"other"}}}"#
            .write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        #expect(try setup.installMCPServer().action == .updated)
        let servers = try #require(try json(".mcp.json")["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        let swapify = try #require(servers["swapify"] as? [String: Any])
        #expect(swapify["args"] as? [String] == ["mcp"])
        #expect(try setup.installMCPServer().action == .unchanged)
    }

    @Test func gitignoreGetsTheStateDirectoryOnce() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "build/".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        #expect(try setup.ignoreStateDirectory()?.action == .updated)
        #expect(try setup.ignoreStateDirectory()?.action == .unchanged)
        let text = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(text == "build/\n.swapify/\n")
    }

    @Test func configurationRoundTrips() throws {
        let configuration = Configuration(project: "App.xcworkspace", scheme: "App")
        #expect(try setup.writeConfiguration(configuration).action == .created)
        #expect(try setup.writeConfiguration(configuration).action == .unchanged)
        #expect(try Configuration.load(from: root) == configuration)
        #expect(Workspace.find(from: root.appendingPathComponent("Sources/File.swift"))?.root.lastPathComponent
                == root.lastPathComponent)
    }
}
