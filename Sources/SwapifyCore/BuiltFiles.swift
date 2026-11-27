import CryptoKit
import Foundation

/// Copies of the reloadable files as the last build compiled them. A layout check
/// compares the IR of such a copy with the IR of the edit: the device patch's layout
/// guard (LayoutGuard), and the side fields of a simulator patch (SideFields).
struct BuiltFiles {
    let workspace: Workspace

    /// After a build: copies each of `files` that exists, replacing the last build's copies.
    func save(_ files: [String]) throws {
        try? FileManager.default.removeItem(at: workspace.originals)
        for file in files where FileManager.default.fileExists(atPath: file) {
            let copy = copy(of: file)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: copy)
        }
    }

    /// The copy of `file` as it was built. It keeps the file name, which private
    /// symbol names depend on.
    func copy(of file: String) -> URL {
        let digest = SHA256.hash(data: Data(file.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return workspace.originals.appendingPathComponent(digest).appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
    }

    /// The IR of `file` as it was built, compiled from its copy once per build. Nil if
    /// there is no copy, or the copy no longer compiles with the module as it is now.
    func ir(of file: String, command: [String]) throws -> IRModule? {
        let copy = copy(of: file)
        let ir = copy.path + ".ll"
        if !FileManager.default.fileExists(atPath: ir) {
            guard FileManager.default.fileExists(atPath: copy.path) else { return nil }
            let list = URL(fileURLWithPath: copy.path + ".SwiftFileList")
            let replaced = try FrontendCommand.replacing(file, with: copy.path, in: command, list: list)
            guard try Shell.run(FrontendCommand.patchIR(replaced, primary: file, source: copy.path, output: ir)).succeeded
            else { return nil }
        }
        return IRModule(try String(contentsOfFile: ir, encoding: .utf8))
    }
}
