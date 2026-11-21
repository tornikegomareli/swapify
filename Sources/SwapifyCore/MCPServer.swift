import Foundation

/// An MCP server over stdio (newline-delimited JSON-RPC 2.0). It is dual-era:
/// legacy clients (protocol 2025-11-25 and earlier) open with `initialize`,
/// modern clients (2026-07-28) send per-request `_meta` and may call
/// `server/discover`. Both get the same tools.
public final class MCPServer {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        swapify patches edited Swift files into the iOS Simulator app that `run` launched, in about a second, \
        without a rebuild. App state stays. After you edit Swift files, call `reload` with their paths, then \
        check the returned screenshot and visible text. Use `ui` and `tap` to test behavior. If `reload` says \
        the layout changed or a file is new, call `run` to rebuild.
        """

    private let root: URL

    /// `root` is where the search for `swapify.json` starts, usually the
    /// directory the agent launched the server in.
    public init(root: URL) {
        self.root = root
    }

    public func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let reply: [String: Any]?
            if let data = line.data(using: .utf8),
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                reply = handle(message)
            } else {
                reply = error(id: nil, code: -32700, message: "Parse error")
            }
            if let reply, let data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) {
                FileHandle.standardOutput.write(data + Data([0x0A]))
            }
        }
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }  // notification
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any]
        let requested = meta?["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = requested != nil
        if let requested, !Self.modernVersions.contains(requested), method != "initialize" {
            return error(id: id, code: -32022, message: "Unsupported protocol version",
                         data: ["supported": Self.modernVersions + Self.legacyVersions, "requested": requested])
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            return result(id: id, modern: false, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": serverInfo,
                "instructions": Self.instructions,
            ])
        case "server/discover":
            return result(id: id, modern: true, [
                "supportedVersions": Self.modernVersions + Self.legacyVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id: id, modern: modern, [:])
        case "tools/list":
            return result(id: id, modern: modern, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id: id, modern: modern, call(name, arguments))
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    static var tools: [[String: Any]] { [
        tool("reload", """
            Patch edited Swift files into the running app without a rebuild, refresh SwiftUI, and return a \
            screenshot and the visible text. Pass every Swift file you changed.
            """, properties: ["files": ["type": "array", "items": ["type": "string"],
                                        "description": "Paths of the edited Swift files, absolute or relative to the project."]],
             required: ["files"]),
        tool("ui", "List the visible accessibility elements, top to bottom: label, traits, and frame in points."),
        tool("tap", "Activate the visible element with this accessibility label or identifier, then return the visible text.",
             properties: ["label": ["type": "string", "description": "Accessibility label or identifier."]],
             required: ["label"]),
        tool("screenshot", "Capture the app. Set full to capture the whole simulator screen, including system alerts.",
             properties: ["full": ["type": "boolean", "description": "Capture the whole simulator screen."]]),
        tool("run", "Build the app with reload support and launch it in the simulator. Use it first, and when reload asks for a rebuild."),
        tool("status", "Check Xcode, the project, the build, the simulator, and the running app."),
    ] }

    private static func tool(_ name: String, _ description: String, properties: [String: Any] = [:],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            guard let workspace = Workspace.find(from: root) else {
                return failure("No swapify.json in \(root.path) or above. Run `swapify init` in the project directory.")
            }
            let agent = Agent(port: workspace.loadSession().port)
            switch name {
            case "reload":
                let files = arguments["files"] as? [String] ?? []
                guard !files.isEmpty else { return failure("Pass the edited files in `files`.") }
                let report = try Reloader(workspace: workspace).reload(files: files)
                var content = [text(report.summary)]
                if let screenshot = report.screenshot, let image = image(screenshot) { content.append(image) }
                return ["content": content, "isError": report.status != .live]
            case "ui":
                let elements = try agent.send("ui", as: AgentUI.self).elements ?? []
                return ["content": [text(elements.map(Self.describe).joined(separator: "\n"))]]
            case "tap":
                guard let label = arguments["label"] as? String else { return failure("Pass `label`.") }
                let tap = try agent.send("tap \(label)", as: AgentTap.self)
                guard tap.ok else { return failure(tap.error ?? "The element did not respond to activation.") }
                Thread.sleep(forTimeInterval: 0.3)
                let visible = try Reloader(workspace: workspace).visibleText(agent)
                return ["content": [text("Tapped \"\(tap.element?.label ?? label)\". Visible text: "
                                         + visible.joined(separator: " | "))]]
            case "screenshot":
                let path: String
                if arguments["full"] as? Bool == true {
                    let session = workspace.loadSession()
                    guard let udid = session.udid else { return failure("No simulator yet. Call `run`.") }
                    let url = workspace.screens.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png")
                    try FileManager.default.createDirectory(at: workspace.screens, withIntermediateDirectories: true)
                    try Simulator(deviceSet: session.deviceSet).screenshot(on: udid, to: url)
                    path = url.path
                } else {
                    path = try Reloader(workspace: workspace).capture(agent, name: "app-\(Int(Date().timeIntervalSince1970))")
                }
                return ["content": [text(path)] + (image(path).map { [$0] } ?? [])]
            case "run":
                let launcher = Launcher(workspace: workspace)
                let build = try launcher.build()
                let launch = try launcher.launch(udid: workspace.loadSession().udid,
                                                 deviceSet: workspace.loadSession().deviceSet)
                let warmup = launch.warmup.map { $0.status == .live ? "Warm-up reload passed." : $0.summary } ?? ""
                return ["content": [text("Built \(URL(fileURLWithPath: build.app).lastPathComponent) in \(build.ms) ms "
                                         + "(\(build.reloadableFiles) reloadable files) and launched it on \(launch.udid). \(warmup)")]]
            case "status":
                let checks = Doctor(workspace: workspace).run()
                return ["content": [text(checks.map { "\($0.status.rawValue): \($0.name): \($0.detail)" }.joined(separator: "\n"))]]
            default:
                return failure("Unknown tool \(name)")
            }
        } catch {
            return failure("\(error)")
        }
    }

    public static func describe(_ element: UIElement) -> String {
        let frame = element.frame.map { String(Int($0)) }
        let traits = element.traits.isEmpty ? "" : "[\(element.traits.joined(separator: ","))] "
        let value = element.value.isEmpty ? "" : " = \(element.value)"
        return "\(traits)\(element.label)\(value)  @ \(frame.joined(separator: ","))"
    }

    // MARK: JSON-RPC

    private var serverInfo: [String: Any] { ["name": "swapify", "version": SwapifyInfo.version] }

    private func result(id: Any, modern: Bool, _ body: [String: Any]) -> [String: Any] {
        var body = body
        body["resultType"] = "complete"
        if modern { body["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo] }
        return ["jsonrpc": "2.0", "id": id, "result": body]
    }

    private func error(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var reply: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { reply["id"] = id }
        return reply
    }

    private func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

    private func image(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [text(message)], "isError": true]
    }
}
