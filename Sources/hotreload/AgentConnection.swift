import Foundation

/// A line-based TCP connection to HotAgent inside the app.
struct AgentConnection {
    /// Sends one command and returns the agent's JSON reply.
    func send(_ command: String) throws -> [String: Any] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = State.agentPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw CommandError(description: "Agent is not running") }

        let line = Array((command + "\n").utf8)
        guard write(fd, line, line.count) == line.count else {
            throw CommandError(description: "Write to agent failed")
        }
        var reply = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n") { reply.append(byte) }
        guard let json = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw CommandError(description: "Agent closed the connection (did the app crash?)")
        }
        return json
    }
}
