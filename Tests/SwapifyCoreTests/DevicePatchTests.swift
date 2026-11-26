import Foundation
import Testing
@testable import SwapifyCore

/// The iOS SDK, which the device pipeline compiles against.
private let iOSSDK: String? = {
    let result = try? Shell.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
    return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}()

/// The device patch pipeline on a two-file module, compiled for iOS with the real
/// toolchain. No phone is needed: the patch is built, guarded, bound, linked, and
/// signed ad hoc on the Mac.
@Suite(.enabled(if: iOSSDK != nil, "needs Xcode with the iOS SDK"))
struct DevicePatchTests {

    let workspace = Workspace(root: FileManager.default.temporaryDirectory.appendingPathComponent("swapify-\(UUID().uuidString)"))
    var view: String { workspace.root.path + "/App/View.swift" }
    var card: String { workspace.root.path + "/App/Card.swift" }

    /// A device session whose build compiled `View.swift`, with its copy for the guard.
    func setUp() throws -> Session {
        try FileManager.default.createDirectory(atPath: workspace.root.path + "/App", withIntermediateDirectories: true)
        try "struct Model { var count = 1 }\nfunc render() -> String { \"\\(Model().count)\" }\n"
            .write(toFile: view, atomically: true, encoding: .utf8)
        let frontend = try Shell.run(["xcrun", "--find", "swift-frontend"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = Session()
        session.deviceName = "Phone"
        session.signingIdentity = "-"
        session.commands[view] = [frontend, "-frontend", "-c", "-primary-file", view, "-module-name", "App",
                                  "-target", "arm64-apple-ios27.0", "-sdk", iOSSDK!, "-enable-implicit-dynamic", "-Onone"]
        try FileManager.default.createDirectory(at: workspace.stateDirectory, withIntermediateDirectories: true)
        try "0x00001000  _$s3App6renderSSyF\n".write(to: workspace.exports, atomically: true, encoding: .utf8)
        let copy = DevicePatches(workspace: workspace).original(of: view)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: view, toPath: copy.path)
        return session
    }

    func reload(_ files: [String], _ session: inout Session) throws -> DevicePatches.Outcome {
        #expect(session.recordReload(of: files, root: workspace.root.path) == nil)
        let directory = workspace.patches.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = try Reloader(workspace: workspace).patchSources(files, session: session, directory: directory)
        return try DevicePatches(workspace: workspace).build(sources: sources, session: session, directory: directory)
    }

    @Test func aNewFileHasNoGuardAndItsTypeMayChangeLayout() throws {
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var session = try setUp()

        try "struct Card { var title = \"Run\" }\n".write(toFile: card, atomically: true, encoding: .utf8)
        guard case .built(_, _, _, let warnings) = try reload([card], &session) else {
            Issue.record("the new file did not build")
            return
        }
        #expect(warnings.isEmpty)

        // The new type gains a stored property, and the existing file starts to use it.
        try "struct Card { var title = \"Run\"; var detail = \"5 km\" }\n".write(toFile: card, atomically: true, encoding: .utf8)
        try "struct Model { var count = 1 }\nfunc render() -> String { \"\\(Model().count) \\(Card().detail)\" }\n"
            .write(toFile: view, atomically: true, encoding: .utf8)
        guard case .built(let dylib, _, _, let later) = try reload([view], &session) else {
            Issue.record("the changed files did not build")
            return
        }
        #expect(later.isEmpty)
        // The patch defines the new copy of Card, which View.swift's code uses.
        let symbols = try Shell.run(["xcrun", "nm", "-U", dylib.path]).output
        #expect(symbols.contains("_$s3App4CardV6detailSSvg"))
    }

    /// The new file's module never names the view's metadata, only the existing
    /// file's module does. The patch must still define it.
    @Test func anExistingFileCanUseANewFilesView() throws {
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var session = try setUp()

        let chip = workspace.root.path + "/App/Chip.swift"
        try "import SwiftUI\nstruct Chip: View {\n    var body: some View { Text(\"Run\") }\n}\n"
            .write(toFile: chip, atomically: true, encoding: .utf8)
        guard case .built = try reload([chip], &session) else {
            Issue.record("the new file did not build")
            return
        }
        try ("import SwiftUI\nstruct Model { var count = 1 }\nfunc render() -> String { \"\\(Model().count)\" }\n"
            + "func screen() -> some View { VStack { Chip() } }\n")
            .write(toFile: view, atomically: true, encoding: .utf8)
        guard case .built(let dylib, _, _, _) = try reload([view], &session) else {
            Issue.record("the changed files did not build")
            return
        }
        let defined = try Shell.run(["xcrun", "nm", "-U", "-j", dylib.path]).output.split(separator: "\n")
        let undefined = try Shell.run(["xcrun", "nm", "-u", "-j", dylib.path]).output.split(separator: "\n")
        #expect(defined.contains("_$s3App4ChipVN"))
        #expect(!undefined.contains { $0.hasPrefix("_$s3App4Chip") })
    }

    @Test func anAppTypeStillRefusesALayoutChange() throws {
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        var session = try setUp()
        try "struct Model { var count = 1; var total = 2 }\nfunc render() -> String { \"\\(Model().count)\" }\n"
            .write(toFile: view, atomically: true, encoding: .utf8)
        guard case .layoutChanged(let type, let reason) = try reload([view], &session) else {
            Issue.record("expected a layout change")
            return
        }
        #expect(type == "$s3App5ModelVMn")
        #expect(reason == "stored properties changed")
    }
}
