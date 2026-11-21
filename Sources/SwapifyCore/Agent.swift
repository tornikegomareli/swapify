import Foundation

/// The wire protocol version this CLI speaks. See docs/protocol.md.
public let agentProtocolVersion = 1

public struct AgentPing: Decodable, Sendable {
    public var ok: Bool
    public var `protocol`: Int?
    public var generation: Int
    public var bundleID: String
    public var swiftUIRefresh: Bool?
}

public struct AgentLoad: Decodable, Sendable {
    public var ok: Bool
    public var generation: Int?
    public var replaced: Int?
    public var added: Int?
    public var dlopenMs: Double?
    public var patchMs: Double?
    public var error: String?
    public var needsRebuild: Bool?
    public var type: String?
    public var reason: String?
}

public struct AgentRefresh: Decodable, Sendable {
    public var ok: Bool
    public var hosts: Int?
    public var ms: Double?
    public var error: String?
}

public struct AgentSnapshot: Decodable, Sendable {
    public var ok: Bool
    public var path: String?
    public var error: String?
}

public struct UIElement: Codable, Sendable, Equatable {
    public var label: String
    public var value: String
    public var identifier: String?
    public var traits: [String]
    /// x, y, width, height in points.
    public var frame: [Double]
}

public struct AgentUI: Decodable, Sendable {
    public var ok: Bool
    public var elements: [UIElement]?
}

public struct AgentTap: Decodable, Sendable {
    public var ok: Bool
    public var element: UIElement?
    public var error: String?
}

/// A connection to SwapifyAgent inside the app: one command per line, one JSON
/// object per line back, on 127.0.0.1.
public struct Agent: Sendable {
    public var port: UInt16

    public init(port: UInt16) {
        self.port = port
    }

    public func send<Reply: Decodable>(_ command: String, as reply: Reply.Type) throws -> Reply {
        let line = try sendRaw(command)
        do {
            return try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
        } catch {
            throw SwapifyError("Unexpected agent reply to `\(command)`: \(line)")
        }
    }

    public func ping() throws -> AgentPing { try send("ping", as: AgentPing.self) }

    public func sendRaw(_ command: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard port != 0, connected == 0 else {
            throw SwapifyError("The app is not running with swapify. Run `swapify run`.")
        }
        // A suspended app (in the background, or stopped in a debugger) never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let bytes = Array((command + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw SwapifyError("Cannot write to the agent") }
        var reply = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { reply.append(byte) }
        guard !reply.isEmpty else {
            throw SwapifyError(
                "The app did not answer. It crashed, or it is suspended: in the background or stopped in the debugger.")
        }
        return String(decoding: reply, as: UTF8.self)
    }

    /// A TCP port on 127.0.0.1 that is free now. Simulator apps share the
    /// host's network stack, so the app can listen on it.
    public static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw SwapifyError("No free TCP port on 127.0.0.1") }
        return UInt16(bigEndian: address.sin_port)
    }
}
