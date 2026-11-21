import Foundation

/// A line-based TCP connection to HotAgent inside the app.
struct AgentConnection {
    var port = State.load().port

    /// Sends one command and returns the agent's JSON reply.
    func send(_ command: String) throws -> [String: Any] {
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
        guard connected == 0 else { throw CommandError(description: "Agent is not running") }
        // A suspended app (in the background, or stopped in a debugger) never answers.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let line = Array((command + "\n").utf8)
        guard write(fd, line, line.count) == line.count else {
            throw CommandError(description: "Write to agent failed")
        }
        var reply = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { reply.append(byte) }
        guard !reply.isEmpty, let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw CommandError(description: "The app did not answer. It crashed, or it is suspended: "
                               + "in the background or stopped in the debugger.")
        }
        return json
    }
}

/// A TCP port on 127.0.0.1 that is free now. Simulator apps share the host's
/// network, so the app can listen on it.
func freePort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard ok else { throw CommandError(description: "No free TCP port") }
    return UInt16(bigEndian: address.sin_port)
}
