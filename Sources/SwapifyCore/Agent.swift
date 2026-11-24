import Foundation

/// The wire protocol version this CLI speaks. See docs/protocol.md.
public let agentProtocolVersion = 1

public struct AgentPing: Decodable, Sendable {
    public var ok: Bool
    public var `protocol`: Int?
    public var generation: Int
    public var bundleID: String
    public var swiftUIRefresh: Bool?
    /// Set by a device agent: whether a debugger is attached (P_TRACED).
    public var traced: Bool?
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
/// object per line back. A simulator app listens on 127.0.0.1. A device app listens
/// on the device, the CLI reaches it through the CoreDevice tunnel address, and each
/// connection starts with `auth <token>`.
public struct Agent: Sendable {
    public var port: UInt16
    /// The device's CoreDevice tunnel address, or nil for a simulator app.
    public var host: String?
    /// The session token a device agent asks for first.
    public var token: String?

    public init(port: UInt16, host: String? = nil, token: String? = nil) {
        self.port = port
        self.host = host
        self.token = token
    }

    public init(session: Session) {
        self.init(port: session.port, host: session.host, token: session.token)
    }

    public func send<Reply: Decodable>(_ command: String, payload: Data = Data(), as reply: Reply.Type) throws -> Reply {
        let line = try sendRaw(command, payload: payload)
        do {
            return try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
        } catch {
            throw SwapifyError("Unexpected agent reply to `\(command)`: \(line.prefix(500))")
        }
    }

    public func ping() throws -> AgentPing { try send("ping", as: AgentPing.self) }

    /// Sends one command line, then `payload` as raw bytes, and returns the reply line.
    public func sendRaw(_ command: String, payload: Data = Data()) throws -> String {
        let fd = try connectSocket()
        defer { close(fd) }
        // A suspended app (in the background, or stopped in a debugger) never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var reader = LineReader(fd: fd)
        if let token {
            try writeAll(fd, Data("auth \(token)\n".utf8))
            guard (try? reader.line())?.contains(#""ok":true"#) == true else {
                throw SwapifyError("The agent refused the session token. Run `swapify run --device` again.")
            }
        }
        try writeAll(fd, Data((command + "\n").utf8) + payload)
        guard let reply = try? reader.line(), !reply.isEmpty else {
            throw SwapifyError(
                "The app did not answer. It crashed, or it is suspended: in the background or stopped in the debugger.")
        }
        return reply
    }

    private func connectSocket() throws -> Int32 {
        guard port != 0 else { throw SwapifyError("The app is not running with swapify. Run `swapify run`.") }
        guard let host else {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(fd)
                throw SwapifyError("The app is not running with swapify. Run `swapify run`.")
            }
            return fd
        }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let address = info else {
            throw SwapifyError("\(host) is not an address.")
        }
        defer { freeaddrinfo(info) }
        let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
        // A device that went away leaves the connect hanging, so wait 5 s at most.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let started = connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0
            || (errno == EINPROGRESS && poll(&ready, 1, 5000) == 1
                && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0)
        guard started else {
            close(fd)
            throw SwapifyError("Cannot reach the app on the device at [\(host)]:\(port).")
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                guard n > 0 else { throw SwapifyError("Cannot write to the agent") }
                sent += n
            }
        }
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

/// Reads newline-terminated lines from a socket, in chunks.
private struct LineReader {
    let fd: Int32
    var buffer = Data()

    mutating func line() throws -> String {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...end)
                return line
            }
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw SwapifyError("The agent closed the connection.") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
