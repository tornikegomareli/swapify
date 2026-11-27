import Foundation
import Testing
@testable import SwapifyCore

/// The iOS simulator SDK, which simulator patches compile against.
private let simulatorSDK: String? = {
    let result = try? Shell.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}()

/// MetadataSlots on a file compiled for the iOS simulator with the real toolchain: a private
/// struct with static metadata, used as a generic argument as `.modifier(Reveal())` uses it
/// (issue #7). scripts/e2e.py checks in an app that patched code gets the app's metadata.
@Suite(.enabled(if: simulatorSDK != nil, "needs Xcode with the iOS simulator SDK"))
struct MetadataSlotsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("swapify-slots-\(UUID().uuidString)")

    func compile(_ source: String) throws -> (ir: String, command: [String]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("View.swift").path
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        let frontend = try Shell.run(["xcrun", "--find", "swift-frontend"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = [frontend, "-frontend", "-c", "-primary-file", file, "-module-name", "App",
                       "-target", "arm64-apple-ios27.0-simulator", "-sdk", simulatorSDK!,
                       "-enable-implicit-dynamic", "-Onone", "-parse-as-library"]
        let run = try Shell.run(FrontendCommand.patchIR(command, primary: file, output: file + ".ll"))
        try #require(run.succeeded, "\(run.output)")
        return (try String(contentsOfFile: file + ".ll", encoding: .utf8), command)
    }

    @Test func codeReadsStaticMetadataThroughASlot() throws {
        let (ir, command) = try compile("""
            private struct Probe {}

            func box<T>(_ value: T) -> Any.Type { T.self }

            func probe() -> Any.Type { box(Probe()) }

            """)
        let metadata = "$s3App5Probe33_"
        // As compiled, `probe()` passes the patch's own metadata to `box`.
        let before = function(ir, "$s3App5probeypXpyF")
        #expect(before.contains("ptr @\"\(metadata)") || before.contains("Mf\", i32 0, i32"))

        let rewritten = MetadataSlots.rewrite(ir)
        let after = function(rewritten, "$s3App5probeypXpyF")
        #expect(after.contains("load ptr, ptr @\"swapify.meta.\(metadata)"))
        #expect(!after.contains("VMf\", i32 0, i32") && !after.contains("ptr @\"\(metadata)"))
        let escaped = NSRegularExpression.escapedPattern(for: metadata)
        #expect(rewritten.range(of: "@\"swapify\\.meta\\.\(escaped)[^\"]*VN\" = internal global ptr @\"\(escaped)[^\"]*VN\"",
                                options: .regularExpression) != nil)

        // The metadata accessor returns an aggregate constant, which cannot hold a load. It
        // keeps the direct reference; the agent jumps the accessor to the app's.
        #expect(function(rewritten, metadata, suffix: "VMa").contains("VMf\", i32 0, i32"))

        let path = root.appendingPathComponent("slots.ll").path
        try rewritten.write(toFile: path, atomically: true, encoding: .utf8)
        let object = try Shell.run(FrontendCommand.compileIR(command, ir: path, output: path + ".o"))
        #expect(object.succeeded, "\(object.output.prefix(1500))")
    }

    @Test func aFileWithoutStaticMetadataIsUnchanged() {
        let ir = "define void @f() {\nentry:\n  ret void\n}\n"
        #expect(MetadataSlots.rewrite(ir) == ir)
    }

    /// The lines of the first function whose name starts with `prefix` and ends with `suffix`.
    func function(_ ir: String, _ prefix: String, suffix: String = "") -> String {
        let lines = ir.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            line.hasPrefix("define ") && line.contains("@\"\(prefix)") && line.contains("\(suffix)\"(")
        }) else { return "" }
        return lines[start...].prefix { $0 != "}" }.joined(separator: "\n")
    }
}
