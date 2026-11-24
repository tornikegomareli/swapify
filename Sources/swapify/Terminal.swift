import Foundation
import SwapifyCore

/// Plain-text output for people, JSON for programs.
enum Terminal {
    static let colors = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func paint(_ text: String, _ code: String) -> String {
        colors ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func green(_ text: String) -> String { paint(text, "32") }
    static func yellow(_ text: String) -> String { paint(text, "33") }
    static func red(_ text: String) -> String { paint(text, "31") }
    static func dim(_ text: String) -> String { paint(text, "2") }
    static func bold(_ text: String) -> String { paint(text, "1") }

    /// Progress goes to stderr, so stdout stays clean for `--json`.
    static func progress(_ text: String) {
        FileHandle.standardError.write(Data((dim(text) + "\n").utf8))
    }

    static func json(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func display(_ report: ReloadReport) {
        let names = report.files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        switch report.status {
        case .live:
            let t = report.timings
            print("\(green("✓ live")) \(bold(names))  \(dim("generation \(report.generation ?? 0)"))")
            let send = t.transfer.map { " · send \($0) ms" } ?? ""
            print(dim("  compile \(t.compile) ms · link \(t.link) ms\(send) · patch \(t.patch) ms · refresh \(t.refresh) ms · total \(t.total) ms"))
            if let screenshot = report.screenshot { print("  \(dim("screenshot")) \(screenshot)") }
            if let text = report.visibleText, !text.isEmpty { print("  \(dim("visible   ")) \(text.joined(separator: " | "))") }
            for warning in report.errors { print("  \(yellow("warning")) \(warning)") }
        case .compileError:
            print("\(red("✗ does not compile")) \(bold(names))")
            report.errors.forEach { print("  \($0)") }
        case .needsRebuild:
            print("\(yellow("! needs a rebuild")) \(bold(names))")
            print("  The layout of \(report.changedType ?? "a type") changed\(report.reason.map { ": \($0)" } ?? "").")
            print("  The app still runs the previous code. Run `\(report.rebuildCommand ?? "swapify run")` to apply it.")
        case .failed:
            print("\(red("✗ not applied")) \(bold(names))")
            report.errors.forEach { print("  \($0)") }
        }
    }

    static func display(_ change: Setup.Change, note: String = "") {
        let action: String
        switch change.action {
        case .created: action = green("created  ")
        case .updated: action = yellow("updated  ")
        case .unchanged: action = dim("unchanged")
        }
        print("  \(change.file.padding(toLength: 34, withPad: " ", startingAt: 0)) \(action) \(dim(note))")
    }

    static func display(_ check: Doctor.Check) {
        let mark: String
        switch check.status {
        case .ok: mark = green("✓")
        case .warning: mark = yellow("!")
        case .failure: mark = red("✗")
        }
        print("\(mark) \(bold(check.name.padding(toLength: 10, withPad: " ", startingAt: 0))) \(check.detail)")
    }
}
