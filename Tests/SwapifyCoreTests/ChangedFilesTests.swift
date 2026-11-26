import Foundation
import Testing
@testable import SwapifyCore

/// A temporary project directory with real files, which the session prunes by existence.
private struct Project {
    let root = realPath(FileManager.default.temporaryDirectory.path) + "/swapify-\(UUID().uuidString)"

    func file(_ relative: String) -> String {
        let path = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    /// A session whose build compiled `files`, all in module `module`.
    func session(compiled files: [String], module: String = "App") -> Session {
        var session = Session()
        for file in files {
            session.commands[file] = ["swift-frontend", "-frontend", "-c"] + files.filter { $0 != file }
                + ["-primary-file", file, "-module-name", module]
        }
        return session
    }
}

@Suite struct BorrowedCommandTests {
    @Test func borrowsFromTheSameFolderFirst() {
        let session = Project().session(compiled: ["/r/App/B.swift", "/r/App/A.swift", "/r/App/Views/C.swift"])
        #expect(session.nearestCompiledFile(to: "/r/App/Views/New.swift", root: "/r") == "/r/App/Views/C.swift")
        #expect(session.nearestCompiledFile(to: "/r/App/New.swift", root: "/r") == "/r/App/A.swift")
    }

    @Test func thenSearchesParentFoldersUpToTheRoot() {
        let session = Project().session(compiled: ["/r/App/A.swift"])
        #expect(session.nearestCompiledFile(to: "/r/App/Settings/Rows/New.swift", root: "/r") == "/r/App/A.swift")
        #expect(session.nearestCompiledFile(to: "/r/AppTests/New.swift", root: "/r") == nil)
        #expect(session.nearestCompiledFile(to: "/elsewhere/New.swift", root: "/r") == nil)
    }

    @Test func neverBorrowsForAPackageManifest() {
        let session = Project().session(compiled: ["/r/Kit/Package.swift.txt", "/r/Kit/A.swift"])
        #expect(session.nearestCompiledFile(to: "/r/Kit/Package.swift", root: "/r") == nil)
    }

    @Test func recordsTheBorrowedFileInTheSession() throws {
        let project = Project()
        defer { project.remove() }
        let app = project.file("App/A.swift"), new = project.file("App/Card.swift")
        var session = project.session(compiled: [app])
        #expect(session.recordReload(of: [new], root: project.root) == nil)
        #expect(session.borrowed == [new: app])

        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data).borrowed == [new: app])
    }

    @Test func explainsAFileWithNoCompiledFileNearIt() {
        let project = Project()
        defer { project.remove() }
        var session = project.session(compiled: [project.file("App/A.swift")])
        let problem = session.recordReload(of: [project.file("Tools/Script.swift")], root: project.root)
        #expect(problem?.hasPrefix("Script.swift is not part of the running app's build") == true)
        #expect(session.borrowed.isEmpty)
    }
}

@Suite struct ChangedSetTests {
    @Test func everyReloadedFileAndEveryNewFileIsCompiled() {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), b = project.file("App/B.swift"), new = project.file("App/New.swift")
        var session = project.session(compiled: [a, b])
        _ = session.recordReload(of: [b], root: project.root)
        _ = session.recordReload(of: [new], root: project.root)
        _ = session.recordReload(of: [b], root: project.root)
        #expect(session.changed == [b, new])
        #expect(session.filesToCompile(for: [a]) == [a, b, new])
    }

    @Test func aWarmUpDoesNotJoinTheChangedSet() {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift")
        var session = project.session(compiled: [a])
        _ = session.recordReload(of: [a], root: project.root, markChanged: false)
        #expect(session.changed.isEmpty)
        #expect(session.filesToCompile(for: [a]) == [a])
    }

    @Test func deletedFilesLeaveTheSet() throws {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), new = project.file("App/New.swift")
        var session = project.session(compiled: [a])
        _ = session.recordReload(of: [new], root: project.root)
        try FileManager.default.removeItem(atPath: new)
        _ = session.recordReload(of: [a], root: project.root)
        #expect(session.borrowed.isEmpty)
        #expect(session.filesToCompile(for: [a]) == [a])
    }

    @Test func aBuildClearsTheSetAndAdoptsNewFilesItCompiled() {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), adopted = project.file("App/Card.swift"), outside = project.file("App/Row.swift")
        var session = project.session(compiled: [a])
        _ = session.recordReload(of: [a, adopted, outside], root: project.root)
        let notInTarget = session.recordBuild([adopted: ["swift-frontend", "-primary-file", adopted]])
        #expect(notInTarget == [outside])
        #expect(session.changed.isEmpty)
        #expect(session.borrowed == [outside: a])
        #expect(session.commands[adopted] != nil)
        #expect(BuildReport.notInTargetMessages(notInTarget) == ["Row.swift is not in the target; add it in Xcode."])
    }

    /// An earlier build, maybe for the other platform, compiled a file that is gone now.
    @Test func aBuildDropsTheCommandsOfDeletedFiles() throws {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), card = project.file("App/Card.swift")
        var session = project.session(compiled: [a, card])
        try FileManager.default.removeItem(atPath: card)
        _ = session.recordBuild([a: ["swift-frontend", "-primary-file", a]])
        #expect(Array(session.commands.keys) == [a])

        // Created again, the file borrows a command of this build.
        _ = project.file("App/Card.swift")
        #expect(session.recordReload(of: [card], root: project.root) == nil)
        #expect(session.borrowed == [card: a])
    }
}

@Suite struct ExtraInputTests {
    @Test func aNewFileCompilesWithTheBorrowedCommandAndItself() throws {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), card = project.file("App/Card.swift"), row = project.file("App/Row.swift")
        var session = project.session(compiled: [a])
        _ = session.recordReload(of: [card, row], root: project.root)
        let (command, inputs) = try #require(session.patchCommand(for: card))
        #expect(command == session.commands[a])
        #expect(inputs == [card, row])

        // The borrowed file becomes a plain input, and the new file the primary file.
        let patch = FrontendCommand.patch(command + inputs, primary: card, output: "/o/Card.o")
        #expect(patch == ["swift-frontend", "-frontend", "-c", a, "-module-name", "App",
                          "-primary-file", card, row, "-o", "/o/Card.o"])
    }

    @Test func existingFilesGetTheNewFilesOfTheirModuleOnly() throws {
        let project = Project()
        defer { project.remove() }
        let a = project.file("App/A.swift"), badge = project.file("Kit/Badge.swift")
        var session = project.session(compiled: [a])
        session.commands[badge] = ["swift-frontend", "-frontend", "-c", "-primary-file", badge, "-module-name", "Kit"]
        let card = project.file("App/Card.swift"), chip = project.file("Kit/Chip.swift")
        _ = session.recordReload(of: [card, chip], root: project.root)
        #expect(session.patchCommand(for: a)?.inputs == [card])
        #expect(session.patchCommand(for: badge)?.inputs == [chip])
    }

    @Test func aFileListGetsACopyWithTheNewFiles() throws {
        let project = Project()
        defer { project.remove() }
        let list = project.file("build/App.SwiftFileList")
        try "/r/A.swift\n/r/B.swift\n".write(toFile: list, atomically: true, encoding: .utf8)
        let command = ["swift-frontend", "-frontend", "-c", "-filelist", list, "-primary-file", "/r/B.swift"]
        let copy = URL(fileURLWithPath: project.root + "/patch/0.SwiftFileList")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)

        let added = try FrontendCommand.adding(["/r/New.swift"], to: command, list: copy)
        #expect(added == ["swift-frontend", "-frontend", "-c", "-filelist", copy.path, "-primary-file", "/r/B.swift"])
        #expect(try String(contentsOf: copy, encoding: .utf8) == "/r/A.swift\n/r/B.swift\n/r/New.swift\n")
        #expect(try FrontendCommand.adding([], to: command, list: copy) == command)

        // The new file is only in the list, so the patch names it as the primary file.
        let patch = FrontendCommand.patch(added, primary: "/r/New.swift", output: "/o/New.o")
        #expect(patch == ["swift-frontend", "-frontend", "-c", "-filelist", copy.path, "/r/B.swift",
                          "-primary-file", "/r/New.swift", "-o", "/o/New.o"])
    }

    // How many run at once depends on the free cores (concurrentPerform), so the test checks
    // the contract, not the wall clock: results keep their order, and an error is rethrown.
    @Test func parallelCompilesKeepTheirOrderAndRethrow() throws {
        let values = try Shell.parallelMap(Array(0..<6)) { index -> Int in
            Thread.sleep(forTimeInterval: 0.05 * Double(6 - index)) // later items finish first
            return index * 10
        }
        #expect(values == [0, 10, 20, 30, 40, 50])
        #expect(throws: SwapifyError.self) {
            try Shell.parallelMap([1, 2]) { value -> Int in
                if value == 2 { throw SwapifyError("two") }
                return value
            }
        }
    }
}
