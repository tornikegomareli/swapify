import Foundation

/// One compile of a patch.
struct PatchSource: Sendable, Equatable {
    var file: String
    /// The build command that compiles `file`, with the module's new files added.
    var command: [String]
    /// The build did not compile this file, so the app has none of its types.
    var isNew: Bool
}

/// Which files a patch compiles, and with which build commands.
///
/// A patch compiles every file changed since the last build: each file reloaded
/// since then, and each new file. A type that did not exist at build time can only
/// be used by these files, so the code that creates it and the code that reads it
/// always come from the same patch. See docs/architecture.md, "New files".
extension Session {
    /// For a file the build did not compile: the file whose command it borrows. That
    /// is the first compiled file, by path, in the nearest folder that has one: the
    /// file's own folder, then each parent folder up to `root`.
    func nearestCompiledFile(to file: String, root: String) -> String? {
        guard (file as NSString).lastPathComponent != "Package.swift" else { return nil }
        var folder = (file as NSString).deletingLastPathComponent
        while true {
            if let first = commands.keys.filter({ ($0 as NSString).deletingLastPathComponent == folder }).min() {
                return first
            }
            guard folder != root, folder.hasPrefix(root + "/") else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// Records the files of a reload: a file the build did not compile borrows a
    /// command, and with `markChanged` every file joins the changed set. Returns why a
    /// file cannot be compiled, if one cannot.
    mutating func recordReload(of files: [String], root: String, markChanged: Bool = true) -> String? {
        let exists = { (file: String) in FileManager.default.fileExists(atPath: file) }
        borrowed = borrowed.filter { exists($0.key) }
        changed = changed.filter(exists)
        for file in files where commands[file] == nil && borrowed[file] == nil {
            guard let source = nearestCompiledFile(to: file, root: root) else {
                return "\((file as NSString).lastPathComponent) is not part of the running app's build, "
                    + "and no folder above it has a file that is. If it is an app file, add it to the target "
                    + "and run `swapify run\(deviceName == nil ? "" : " --device")`."
            }
            borrowed[file] = source
        }
        if markChanged {
            for file in files where !changed.contains(file) { changed.append(file) }
        }
        return nil
    }

    /// The files a patch for `files` compiles: those, every file reloaded since the
    /// build, and every new file. Sorted.
    func filesToCompile(for files: [String]) -> [String] {
        Set(files + changed + borrowed.keys).sorted()
    }

    /// The build command that compiles `file` in a patch, its own or the one it
    /// borrows, and the new files of its module that the command does not list.
    func patchCommand(for file: String) -> (command: [String], inputs: [String])? {
        guard let command = commands[file] ?? borrowed[file].flatMap({ commands[$0] }) else { return nil }
        let module = Self.moduleName(command)
        let inputs = borrowed.keys.sorted().filter { new in
            !command.contains(new) && borrowed[new].flatMap { commands[$0] }.map(Self.moduleName) == module
        }
        return (command, inputs)
    }

    /// After a build: the commands it printed, and an empty changed set. A new file
    /// that the build compiled has its own command now. Returns the new files that
    /// the build did not compile: they are not in the target.
    mutating func recordBuild(_ built: [String: [String]]) -> [String] {
        commands.merge(built) { $1 }
        changed = []
        borrowed = borrowed.filter { commands[$0.key] == nil && FileManager.default.fileExists(atPath: $0.key) }
        return borrowed.keys.sorted()
    }

    static func moduleName(_ command: [String]) -> String? {
        command.firstIndex(of: "-module-name").flatMap { $0 + 1 < command.count ? command[$0 + 1] : nil }
    }
}
