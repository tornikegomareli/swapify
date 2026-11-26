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

    enum Outcome {
        /// The signed patch, with milliseconds to compile (IR, guard, binding, objects)
        /// and to link and sign it.
        case built(dylib: URL, compile: Int, link: Int, warnings: [String])
        case compileError([String])
        /// The layout guard refused: `type` is the `$s…Mn` symbol.
        case layoutChanged(type: String, reason: String)
    }

    /// Builds one patch from `sources`, into `directory`. The files compile in parallel.
    /// A new file gets no layout guard: the app has none of its types.
    func build(sources: [PatchSource], session: Session, directory: URL) throws -> Outcome {
        let start = ContinuousClock.now
        let exports = PatchBinder.exports(fromDyldInfo: (try? String(contentsOf: workspace.exports, encoding: .utf8)) ?? "")
        guard !exports.isEmpty, let identity = session.signingIdentity else {
            throw SwapifyError("This device build has no record of the app's symbols. Run `swapify run --device`.")
        }
        let stems = sources.enumerated().map { index, source in
            directory.appendingPathComponent("\(index)-" + URL(fileURLWithPath: source.file).lastPathComponent).path
        }
        let compiled = try Shell.parallelMap(Array(zip(sources, stems))) { source, stem in try ir(for: source, stem: stem) }
        let errors = Reloader.compileErrors(compiled.compactMap { if case .compileError(let output) = $0 { output } else { nil } })
        if !errors.isEmpty { return .compileError(errors) }
        for case .layoutChanged(let type, let reason) in compiled { return .layoutChanged(type: type, reason: reason) }
        let modules = compiled.compactMap { if case .ir(let module, _) = $0 { module } else { nil } }
        let warnings = compiled.compactMap { if case .ir(_, let warning) = $0 { warning } else { nil } }

        // The modules bind knowing each other: a new type keeps the definitions that
        // the other files of the patch use, such as its metadata.
        let declared = modules.reduce(into: Set<String>()) { $0.formUnion($1.declarations) }
        let paths = try Shell.parallelMap(Array(modules.indices)) { index in
            try object(from: modules[index], stem: stems[index], command: sources[index].command,
                       exports: exports, keep: declared)
        }
        let compileTime = milliseconds(since: start)

        let dylib = directory.appendingPathComponent("patch.dylib")
        let link = try Shell.run(FrontendCommand.link(sources[0].command, objects: paths, output: dylib.path))
        guard link.succeeded else { throw SwapifyError("Linking the patch failed:\n\(link.output)") }
        let sign = try Shell.run(["codesign", "--force", "--sign", identity, dylib.path])
        guard sign.succeeded else { throw SwapifyError("Signing the patch failed:\n\(sign.output)") }
        return .built(dylib: dylib, compile: compileTime, link: milliseconds(since: start) - compileTime, warnings: warnings)
    }

    enum Compiled {
        /// The edit's IR, and a warning if its layout was not checked.
        case ir(IRModule, warning: String?)
        /// The compiler output.
        case compileError(String)
        case layoutChanged(type: String, reason: String)
    }

    /// Compiles one source to `<stem>.ll`, and checks its layout against the build.
    func ir(for source: PatchSource, stem: String) throws -> Compiled {
        let compile = try Shell.run(FrontendCommand.patchIR(source.command, primary: source.file, output: stem + ".ll"))
        guard compile.succeeded else { return .compileError(compile.output) }
        let edited = IRModule(try String(contentsOfFile: stem + ".ll", encoding: .utf8))
        var warning: String?
        if !source.isNew {
            if let before = try builtIR(source.file, command: source.command) {
                if let change = LayoutGuard.change(from: before, to: edited) {
                    return .layoutChanged(type: change.type, reason: change.reason)
                }
            } else {
                warning = "The layout of \(URL(fileURLWithPath: source.file).lastPathComponent) was not checked: "
                    + "its copy from the build no longer compiles."
            }
        }
        return .ir(edited, warning: warning)
    }

    /// Binds one module to the app's exports, keeping the definitions in `keep`, and
    /// compiles the bound IR to `<stem>.o`. Returns the object's path.
    func object(from module: IRModule, stem: String, command: [String], exports: Set<String>,
                keep: Set<String>) throws -> String {
        try PatchBinder.bind(module, exports: exports, keep: keep).ir
            .write(toFile: stem + ".bound.ll", atomically: false, encoding: .utf8)
        let usr = URL(fileURLWithPath: command[0]).deletingLastPathComponent().deletingLastPathComponent()
        let target = command.firstIndex(of: "-target").map { command[$0 + 1] } ?? ""
        let object = try Shell.run([usr.appendingPathComponent("bin/clang").path, "-c", "-target", target, "-O0",
                                    stem + ".bound.ll", "-o", stem + ".o"])
        guard object.succeeded else { throw SwapifyError("Compiling the bound patch failed:\n\(object.output)") }
        return stem + ".o"
    }

    /// The IR of `file` as it was built, compiled from its copy once per build.
    private func builtIR(_ file: String, command: [String]) throws -> IRModule? {
        let copy = original(of: file)
        let ir = copy.path + ".ll"
        if !FileManager.default.fileExists(atPath: ir) {
            guard FileManager.default.fileExists(atPath: copy.path),
                  try Shell.run(FrontendCommand.patchIR(command, primary: file, source: copy.path, output: ir)).succeeded
            else { return nil }
        }
        return IRModule(try String(contentsOfFile: ir, encoding: .utf8))
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
