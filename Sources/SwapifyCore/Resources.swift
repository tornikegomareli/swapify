import Foundation

/// Files swapify ships next to its binary. An installed copy looks in
/// `<prefix>/lib/swapify` and `<prefix>/share/swapify`. A source checkout
/// builds the agent on demand into `.build/agent`.
public enum Resources {
    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var prefix: URL {
        URL(fileURLWithPath: realPath(Bundle.main.executablePath ?? CommandLine.arguments[0]))
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The simulator agent, or with `device` the arm64 iOS one.
    public static func agent(device: Bool = false) throws -> URL {
        let name = device ? "SwapifyAgent-iphoneos.dylib" : "SwapifyAgent.dylib"
        let installed = prefix.appendingPathComponent("lib/swapify/" + name)
        if FileManager.default.fileExists(atPath: installed.path) { return installed }

        let built = sourceRoot.appendingPathComponent(".build/agent/" + name)
        let sources = sourceRoot.appendingPathComponent("Agent")
        guard FileManager.default.fileExists(atPath: sources.path) else {
            throw SwapifyError("SwapifyAgent.dylib is missing from \(installed.deletingLastPathComponent().path). Reinstall swapify.")
        }
        if isOutdated(built, sources: sources) {
            let result = try Shell.run([sourceRoot.appendingPathComponent("scripts/build-agent.sh").path])
            guard result.succeeded else { throw SwapifyError("Building the agent failed:\n\(result.output)") }
        }
        return built
    }

    public static func skill() throws -> String {
        let candidates = [prefix.appendingPathComponent("share/swapify/SKILL.md"),
                          sourceRoot.appendingPathComponent("skills/swapify/SKILL.md")]
        for file in candidates {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        throw SwapifyError("SKILL.md is missing. Reinstall swapify.")
    }

    private static func isOutdated(_ product: URL, sources: URL) -> Bool {
        let fileManager = FileManager.default
        guard let built = (try? fileManager.attributesOfItem(atPath: product.path))?[.modificationDate] as? Date
        else { return true }
        let files = (try? fileManager.contentsOfDirectory(atPath: sources.path)) ?? []
        return files.contains { name in
            let date = (try? fileManager.attributesOfItem(atPath: sources.appendingPathComponent(name).path))?[.modificationDate] as? Date
            return (date ?? .distantFuture) > built
        }
    }
}
