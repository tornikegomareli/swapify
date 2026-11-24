import CryptoKit
import Foundation

/// The patch pipeline for an app on a device. A device cannot write code pages, so
/// a device patch is bound to the app's types by dyld instead of jumping to them:
/// it is compiled to IR, checked by the layout guard against the file as it was
/// built, rewritten by PatchBinder, compiled, linked, and signed with the identity
/// that signed the app. See docs/architecture.md, "On a device".
struct DevicePatches {
    let workspace: Workspace

    /// After a device build: the symbols the app's images export, and a copy of
    /// every reloadable file as it was built, for the layout guard.
    func prepare(app: URL, files: [String]) throws {
        let exports = try Shell.run(["xcrun", "dyld_info", "-exports"] + Self.images(in: app).map(\.path))
        guard exports.succeeded else { throw SwapifyError("dyld_info failed:\n\(exports.output)") }
        try exports.output.write(to: workspace.exports, atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(at: workspace.originals)
        for file in files where FileManager.default.fileExists(atPath: file) {
            let copy = original(of: file)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: copy)
        }
    }

    /// The copy of `file` as it was built. It keeps the file name, which private
    /// symbol names depend on.
    func original(of file: String) -> URL {
        let digest = SHA256.hash(data: Data(file.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return workspace.originals.appendingPathComponent(digest).appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent)
    }

    /// The Mach-O images in an app bundle: the executable, top-level dylibs (Xcode's
    /// `<App>.debug.dylib`), and embedded frameworks.
    static func images(in app: URL) -> [URL] {
        let fileManager = FileManager.default
        let executable = (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleExecutable"] as? String)
            .map { app.appendingPathComponent($0) }
        let dylibs = ((try? fileManager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dylib" }
        let frameworks = ((try? fileManager.contentsOfDirectory(at: app.appendingPathComponent("Frameworks"),
                                                                 includingPropertiesForKeys: nil)) ?? [])
            .map { $0.pathExtension == "framework" ? $0.appendingPathComponent($0.deletingPathExtension().lastPathComponent) : $0 }
        return ([executable].compactMap { $0 } + dylibs + frameworks).filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// The SHA-1 of the certificate that signed `app`, as `codesign --sign` takes it.
    static func signingIdentity(of app: URL) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swapify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = directory.appendingPathComponent("cert").path
        try Shell.run(["codesign", "-d", "--extract-certificates=\(prefix)", app.path])
        guard let certificate = try? Data(contentsOf: URL(fileURLWithPath: prefix + "0")) else {
            throw SwapifyError("\(app.lastPathComponent) is not signed with a certificate. A device build needs the project's signing.")
        }
        return Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }

    /// Signs a copy of the device agent with the app's identity, so the app may load it.
    func signedAgent(identity: String) throws -> URL {
        let copy = workspace.stateDirectory.appendingPathComponent("SwapifyAgent.dylib")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: try Resources.agent(device: true), to: copy)
        let sign = try Shell.run(["codesign", "--force", "--sign", identity, copy.path])
        guard sign.succeeded else { throw SwapifyError("Signing the agent failed:\n\(sign.output)") }
        return copy
    }
}
