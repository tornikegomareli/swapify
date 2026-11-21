import Foundation

struct CommandError: Error, CustomStringConvertible {
    let description: String
}

struct ProcessResult {
    let status: Int32
    let output: String
}

/// Runs a program and returns its exit status and combined output.
/// If `logFile` is set, output goes to that file instead.
@discardableResult
func run(_ arguments: [String], environment: [String: String] = [:], logFile: URL? = nil) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let pipe = Pipe()
    if let logFile {
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = handle
        process.standardError = handle
    } else {
        process.standardOutput = pipe
        process.standardError = pipe
    }
    try process.run()
    let data = logFile == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

/// Splits a command line the way a POSIX shell does: quotes and backslashes.
func shellSplit(_ line: Substring) -> [String] {
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

func printJSON(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}
