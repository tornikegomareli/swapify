import Foundation

public struct SwapifyError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String

    public var succeeded: Bool { status == 0 }
}

public enum Shell {
    /// Runs a program found on PATH and returns its exit status and combined
    /// output. If `log` is set, the output goes to that file instead.
    @discardableResult
    public static func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        log: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        try process.run()
        // Read before waiting, so a full pipe cannot block the child.
        let data = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Splits a command line the way a POSIX shell does: single and double
    /// quotes, and backslash escapes.
    public static func split(_ line: some StringProtocol) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                inWord = true
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

/// The real path, with symlinks resolved and `/private` kept. Simulator tools
/// do not map `/tmp` to `/private/tmp` the way the host does, and
/// `URL.resolvingSymlinksInPath()` strips `/private` on purpose.
func realPath(_ path: String) -> String {
    guard let pointer = realpath(path, nil) else { return path }
    defer { free(pointer) }
    return String(cString: pointer)
}

/// Milliseconds since `start`, for timings in reports.
func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
}
