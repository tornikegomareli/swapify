import Foundation
import Testing
@testable import SwapifyCore

@Suite struct DeviceTokenTests {
    @Test func tokenIs128RandomBits() {
        let token = Session.newToken()
        #expect(token.count == 32)
        #expect(token.allSatisfy { $0.isHexDigit })
        #expect(token != Session.newToken())
    }

    @Test func sessionFileIsReadableByItsOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root)
        var session = Session()
        session.token = Session.newToken()
        try workspace.save(session)
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.sessionFile.path)
        let mode = attributes[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(workspace.loadSession().token == session.token)
    }

    @Test func sendsTheTokenFirst() throws {
        let agent = try FakeDeviceAgent(token: "secret")
        let ping = try Agent(port: agent.port, host: "127.0.0.1", token: "secret").ping()
        #expect(ping.bundleID == "app")
        #expect(agent.lines() == ["auth secret", "ping"])
    }

    @Test func reportsAWrongToken() throws {
        let agent = try FakeDeviceAgent(token: "secret")
        #expect(throws: SwapifyError.self) { try Agent(port: agent.port, host: "127.0.0.1", token: "wrong").ping() }
        #expect(agent.lines() == ["auth wrong"])
    }
}

/// Accepts one connection on 127.0.0.1 and answers like a device agent.
private final class FakeDeviceAgent: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private var received: [String] = []
    private let done = DispatchSemaphore(value: 0)

    init(token: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        listen(fd, 1)
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            let io = fdopen(client, "r+")
            var line = [CChar](repeating: 0, count: 256)
            if fgets(&line, 256, io) != nil {
                received.append(text(line))
                if received[0] == "auth \(token)" {
                    fputs("{\"ok\":true}\n", io)
                    fflush(io)
                    if fgets(&line, 256, io) != nil {
                        received.append(text(line))
                        fputs("{\"ok\":true,\"protocol\":1,\"generation\":0,\"bundleID\":\"app\"}\n", io)
                    }
                } else {
                    fputs("{\"ok\":false,\"error\":\"not authorized\"}\n", io)
                }
            }
            fclose(io)
            close(fd)
            done.signal()
        }
    }

    private func text(_ line: [CChar]) -> String {
        String(decoding: line.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    func lines() -> [String] {
        done.wait()
        return received
    }
}
