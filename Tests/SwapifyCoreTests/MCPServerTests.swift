import Foundation
import Testing
@testable import SwapifyCore

@Suite struct MCPServerTests {
    let server = MCPServer(root: FileManager.default.temporaryDirectory)

    private func request(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private let modern: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [String: Any](),
    ]

    @Test func legacyInitializeNegotiatesALegacyVersion() throws {
        let reply = try #require(server.handle(request("initialize", params: ["protocolVersion": "2025-06-18"])))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "swapify")
    }

    @Test func legacyInitializeFallsBackToTheNewestLegacyVersion() throws {
        let reply = try #require(server.handle(request("initialize", params: ["protocolVersion": "2099-01-01"])))
        #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func discoverListsVersionsAndServerInfo() throws {
        let reply = try #require(server.handle(request("server/discover", params: ["_meta": modern])))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["resultType"] as? String == "complete")
        #expect((result["supportedVersions"] as? [String])?.first == "2026-07-28")
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect(meta["io.modelcontextprotocol/serverInfo"] != nil)
    }

    @Test func unknownModernVersionIsRejectedWithTheSupportedList() throws {
        let meta: [String: Any] = ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]
        let reply = try #require(server.handle(request("tools/list", params: ["_meta": meta])))
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        #expect(((error["data"] as? [String: Any])?["supported"] as? [String])?.contains("2026-07-28") == true)
    }

    @Test func toolsListHasTheReloadLoop() throws {
        let reply = try #require(server.handle(request("tools/list", params: ["_meta": modern])))
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["reload", "ui", "tap", "screenshot", "run", "status"])
    }

    @Test func notificationsGetNoReply() {
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func unknownMethodsAreErrors() throws {
        let reply = try #require(server.handle(request("resources/list")))
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func toolCallsOutsideAProjectExplainWhatToDo() throws {
        let params: [String: Any] = ["name": "status", "arguments": [String: Any](), "_meta": modern]
        let reply = try #require(server.handle(request("tools/call", params: params)))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(text.contains("swapify init"))
    }
}
