import Foundation

/// Claude Code PostToolUse hook. Reads the hook input on stdin. If the edited
/// file is Swift and belongs to a project with a running hotreload session,
/// it reloads the file and returns the result to the model as additionalContext.
func hook() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let json = try JSONSerialization.jsonObject(with: input) as? [String: Any]
    let toolInput = json?["tool_input"] as? [String: Any]
    guard let file = toolInput?["file_path"] as? String, file.hasSuffix(".swift"),
          let root = sessionRoot(for: file) else { return }
    FileManager.default.changeCurrentDirectoryPath(root)

    let message: String
    do {
        message = summary(of: try reload(files: [file]), file: file)
    } catch {
        message = "hotreload: \(URL(fileURLWithPath: file).lastPathComponent) was not reloaded: \(error). "
            + "If the app is not running, run `hotreload launch` in \(root)."
    }
    printJSON(["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": message]])
}

/// The nearest directory above `file` that has a hotreload session.
func sessionRoot(for file: String) -> String? {
    var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".hotreload/state.json").path) {
            return directory.path
        }
        directory.deleteLastPathComponent()
    }
    return nil
}

/// Short, factual text for the model.
func summary(of result: [String: Any], file: String) -> String {
    let name = URL(fileURLWithPath: file).lastPathComponent
    guard result["ok"] as? Bool == true else {
        if result["needsRebuild"] as? Bool == true {
            return "hotreload: \(name) was not applied. The layout of \(result["type"] ?? "a type") changed "
                + "(\(result["reason"] ?? "stored properties or class methods")), which hot reload cannot patch. "
                + "The app still runs the previous code. "
                + "Run `hotreload build --project <project> --scheme <scheme>` and `hotreload launch` to apply it."
        }
        if let errors = result["errors"] as? [String] {
            return "hotreload: \(name) does not compile, so the app still runs the previous code.\n"
                + errors.joined(separator: "\n")
        }
        return "hotreload: \(name) was not applied: \(result)"
    }
    let ms = (result["ms"] as? [String: Int])?["total"] ?? 0
    let text = (result["visibleText"] as? [String] ?? []).prefix(40).joined(separator: " | ")
    return """
        hotreload: \(name) is live in the running simulator app (generation \(result["generation"] ?? 0), \(ms) ms). \
        Screenshot: \(result["screenshot"] ?? ""). Visible text now: \(text)
        """
}
