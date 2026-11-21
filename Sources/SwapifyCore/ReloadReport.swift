import Foundation

/// The result of one reload, for people (`summary`) and programs (JSON).
public struct ReloadReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The new code runs in the app.
        case live
        /// A file does not compile. The app runs the previous code.
        case compileError
        /// The edit changes a type's layout. Rebuild and relaunch to apply it.
        case needsRebuild
        /// Anything else: link, load or agent errors.
        case failed
    }

    public struct Timings: Codable, Sendable {
        public var compile = 0
        public var link = 0
        public var patch = 0
        public var refresh = 0
        public var total = 0
    }

    public var status: Status
    public var files: [String]
    public var generation: Int?
    public var timings = Timings()
    public var screenshot: String?
    public var visibleText: [String]?
    /// Compiler errors, or one message that explains a failure.
    public var errors: [String] = []
    /// The type whose layout changed, for `needsRebuild`.
    public var changedType: String?
    public var reason: String?

    public init(status: Status, files: [String]) {
        self.status = status
        self.files = files
    }

    private var names: String {
        files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
    }

    /// One line for the person who watches the agent.
    public var headline: String {
        switch status {
        case .live: return "swapify: \(names) live in \(timings.total) ms"
        case .compileError: return "swapify: \(names) does not compile, the app keeps the previous code"
        case .needsRebuild: return "swapify: \(names) needs a rebuild, the layout of \(changedType ?? "a type") changed"
        case .failed: return "swapify: \(names) was not applied"
        }
    }

    /// Short, factual text for a coding agent.
    public var summary: String {
        switch status {
        case .live:
            var text = "swapify: \(names) is live in the running app (generation \(generation ?? 0), \(timings.total) ms)."
            if let screenshot { text += " Screenshot: \(screenshot)." }
            if let visibleText { text += " Visible text: " + visibleText.prefix(40).joined(separator: " | ") }
            return text
        case .compileError:
            return "swapify: \(names) does not compile, so the app still runs the previous code.\n"
                + errors.joined(separator: "\n")
        case .needsRebuild:
            return "swapify: \(names) was not applied. The layout of \(changedType ?? "a type") changed"
                + (reason.map { " (\($0))" } ?? "")
                + ", which a reload cannot patch. The app still runs the previous code. Run `swapify run` to rebuild."
        case .failed:
            return "swapify: \(names) was not applied. " + errors.joined(separator: " ")
        }
    }
}
