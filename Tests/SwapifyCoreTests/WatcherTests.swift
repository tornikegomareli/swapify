import Foundation
import Testing
@testable import SwapifyCore

@Suite struct WatcherTests {
    let root = realPath(FileManager.default.temporaryDirectory.path) + "/swapify-\(UUID().uuidString)"

    @discardableResult
    func write(_ relative: String, _ text: String) -> String {
        let path = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: false, encoding: .utf8)
        return path
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    @Test func findsChangedAndNewFilesUnderTheSessionsFolders() {
        defer { remove() }
        let view = write("App/View.swift", "a")
        write("App/Package.swift", "p")
        write("Other/Script.swift", "s")
        var watcher = Watcher(files: [view], root: root)
        #expect(watcher.folders == [root + "/App"])
        #expect(watcher.files == [view])
        #expect(watcher.changes().isEmpty)

        write("App/View.swift", "b")
        let row = write("App/Rows/Row.swift", "r")
        write("Other/Script.swift", "s2")
        #expect(watcher.changes() == [row, view])
        #expect(watcher.changes().isEmpty)
    }

    @Test func skipsHiddenFoldersBuildFoldersAndDerivedData() {
        defer { remove() }
        let main = write("Main.swift", "m")
        write(".swapify/originals/0a/Main.swift", "m")
        write(".build/checkouts/Kit/Kit.swift", "k")
        write("DerivedData/Build/Generated.swift", "g")
        write("App/.hidden.swift", "h")
        let derived = write(".swapify/DerivedData/SourcePackages/checkouts/Kit/Kit.swift", "k")
        let watcher = Watcher(files: [main, derived], root: root)
        #expect(watcher.folders == [root])
        #expect(watcher.files == [main])
    }

    @Test func aSaveOfTheSameTextIsNoChange() {
        defer { remove() }
        let view = write("App/View.swift", "a")
        var watcher = Watcher(files: [view], root: root)
        Thread.sleep(forTimeInterval: 0.01)
        write("App/View.swift", "a")
        #expect(watcher.changes().isEmpty)
    }

    /// Xcode writes a new file, then renames it over the old one.
    @Test func anAtomicSaveIsOneChange() throws {
        defer { remove() }
        let view = write("App/View.swift", "a")
        var watcher = Watcher(files: [view], root: root)
        let temporary = write("saving/View.swift", "b")
        #expect(rename(temporary, view) == 0)
        #expect(watcher.changes() == [view])
        #expect(watcher.changes().isEmpty)
    }

    @Test func waitsForTheWritesToSettle() {
        defer { remove() }
        let a = write("App/A.swift", "a"), b = write("App/B.swift", "b")
        var watcher = Watcher(files: [a, b], root: root)
        let thread = Thread { [self] in
            write("App/A.swift", "a2")
            Thread.sleep(forTimeInterval: 0.1)
            write("App/B.swift", "b2")
        }
        thread.start()
        // B is written after the first scan sees A, but within the settle time.
        #expect(watcher.nextChanges(poll: 0.05, settle: 0.3) == [a, b])

        write("App/B.swift", "b3")
        #expect(watcher.nextChanges(poll: 0.05, settle: 0.3) == [b])
    }
}
