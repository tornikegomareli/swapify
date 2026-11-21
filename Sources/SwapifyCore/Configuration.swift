import Foundation

/// `swapify.json`: the project settings `swapify init` writes. Commit it.
public struct Configuration: Codable, Equatable, Sendable {
    public static let fileName = "swapify.json"

    /// An `.xcodeproj` or `.xcworkspace`, relative to the workspace root.
    public var project: String
    public var scheme: String

    public init(project: String, scheme: String) {
        self.project = project
        self.scheme = scheme
    }

    public static func load(from root: URL) throws -> Configuration {
        let file = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: file) else {
            throw SwapifyError("No \(fileName) in \(root.path). Run `swapify init` first.")
        }
        do {
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            throw SwapifyError("\(file.path) is not valid: \(error)")
        }
    }

    public func save(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent(Configuration.fileName), options: .atomic)
    }
}
