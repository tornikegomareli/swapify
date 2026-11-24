import Foundation
import Testing
@testable import SwapifyCore

@Suite struct DeviceChoiceTests {
    let phone = Device(udid: "00008160-000A", name: "Doomile", developerMode: true)
    let other = Device(udid: "00008150-0006", name: "Test iPhone", developerMode: true)

    @Test func takesTheOnlyConnectedDevice() throws {
        #expect(try Device.choose([phone], query: nil) == phone)
    }

    @Test func explainsHowToConnectWhenNoneIs() {
        #expect(throws: SwapifyError.self) { try Device.choose([], query: nil) }
    }

    @Test func asksWhichWhenSeveralAreConnected() {
        do {
            _ = try Device.choose([phone, other], query: nil)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("Doomile (00008160-000A), Test iPhone (00008150-0006)"))
            #expect("\(error)".contains("--udid"))
        }
    }

    @Test func picksByNameOrUDID() throws {
        #expect(try Device.choose([phone, other], query: "Test iPhone") == other)
        #expect(try Device.choose([phone, other], query: "00008160-000A") == phone)
        #expect(try Device.choose([phone, other], query: "doom") == phone)
        #expect(throws: SwapifyError.self) { try Device.choose([phone, other], query: "iPad") }
    }
}

@Suite struct DeviceBuildTests {
    @Test func deviceBuildsExportPrivateDeclarations() {
        let flags = Xcode.deviceReloadSettings.first { $0.hasPrefix("OTHER_SWIFT_FLAGS=") }
        #expect(flags == "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic -Xfrontend -enable-private-imports")
        #expect(!Xcode.reloadSettings.contains { $0.contains("enable-private-imports") })
    }

    @Test func explainsAMissingSigningTeam() {
        let log = #"error: Signing for "Habits" requires a development team. Select a development team in the Signing & Capabilities editor."#
        #expect(Xcode.signingProblem(inBuildLog: log)?.contains("Signing & Capabilities") == true)
        #expect(Xcode.signingProblem(inBuildLog: "error: cannot find 'x' in scope") == nil)
    }

    @Test func findsTheExecutableTheDebugDylibAndFrameworks() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/Habits.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let framework = app.appendingPathComponent("Frameworks/Kit.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        for file in ["Habits", "Habits.debug.dylib", "Assets.car"] {
            FileManager.default.createFile(atPath: app.appendingPathComponent(file).path, contents: Data())
        }
        FileManager.default.createFile(atPath: framework.appendingPathComponent("Kit").path, contents: Data())
        try (["CFBundleExecutable": "Habits"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        #expect(DevicePatches.images(in: app).map(\.lastPathComponent) == ["Habits", "Habits.debug.dylib", "Kit"])
    }
}
