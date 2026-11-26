import CryptoKit
import Foundation

/// Finds the Swift files that changed on disk, for `swapify watch`: the files of the
/// session, and every Swift file under their folders, new files too. A file changed
/// when its content hash changed, so a save of the same text is no change. Hidden
/// folders, `.build`, `.swapify`, and DerivedData are skipped.
public struct Watcher {
    /// The folders that are scanned, each with its subfolders.
    public let folders: [String]
    private var stamps: [String: Stamp] = [:]
    private var hashes: [String: SHA256.Digest] = [:]

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    /// Watches the folders of `files`. The first scan reads every file, and reports nothing.
    public init(files: [String], root: String) {
        let parents = Set(files.map { ($0 as NSString).deletingLastPathComponent }).filter { !Self.ignores($0, root: root) }
        folders = parents.filter { folder in !parents.contains { folder.hasPrefix($0 + "/") } }.sorted()
        _ = changes()
    }

    /// The watched files, as of the last scan.
    public var files: [String] { stamps.keys.sorted() }

    /// The files whose content differs from the last scan, and new files. Sorted.
    public mutating func changes() -> [String] {
        var seen: [String: Stamp] = [:]
        var changed: [String] = []
        for folder in folders {
            guard let items = FileManager.default.enumerator(atPath: folder) else { continue }
            while let item = items.nextObject() as? String {
                let name = (item as NSString).lastPathComponent
                let attributes = items.fileAttributes ?? [:]
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    if Self.ignores(name) { items.skipDescendants() }
                    continue
                }
                guard name.hasSuffix(".swift"), !name.hasPrefix("."), name != "Package.swift" else { continue }
                let path = folder + "/" + item
                let stamp = Stamp(modified: attributes[.modificationDate] as? Date ?? .distantPast,
                                  size: (attributes[.size] as? NSNumber)?.intValue ?? 0)
                if stamps[path] == stamp {
                    seen[path] = stamp
                    continue
                }
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                seen[path] = stamp
                let hash = SHA256.hash(data: data)
                if hashes.updateValue(hash, forKey: path) != hash { changed.append(path) }
            }
        }
        stamps = seen
        return changed.sorted()
    }

    /// Waits until files change, then until no file changed for `settle` seconds, so
    /// the writes of one save are one batch. Scans every `poll` seconds.
    public mutating func nextChanges(poll: TimeInterval = 0.25, settle: TimeInterval = 0.15) -> [String] {
        var batch = Set<String>()
        while batch.isEmpty {
            Thread.sleep(forTimeInterval: poll)
            batch.formUnion(changes())
        }
        while true {
            Thread.sleep(forTimeInterval: settle)
            let more = changes()
            if more.isEmpty { return batch.sorted() }
            batch.formUnion(more)
        }
    }

    /// Whether `folder`, or a folder above it up to `root`, is skipped.
    static func ignores(_ folder: String, root: String) -> Bool {
        let relative = folder == root ? "" : folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) : folder
        return relative.split(separator: "/").contains { ignores(String($0)) }
    }

    /// Hidden folders, which include `.build` and `.swapify`, and DerivedData.
    static func ignores(_ folderName: String) -> Bool {
        folderName.hasPrefix(".") || folderName == "DerivedData"
    }
}
