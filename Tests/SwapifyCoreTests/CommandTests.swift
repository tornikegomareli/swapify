import Foundation
import Testing
@testable import SwapifyCore

@Suite struct ShellSplitTests {
    @Test func splitsOnSpaces() {
        #expect(Shell.split("swift-frontend -frontend -c  a.swift") == ["swift-frontend", "-frontend", "-c", "a.swift"])
    }

    @Test func keepsEscapesFromXcodeLogs() {
        let line = ##"-load-resolved-plugin /x/lib.dylib\#/x/server\#Macros -debug-info-format\=dwarf"##
        #expect(Shell.split(line) == ["-load-resolved-plugin", "/x/lib.dylib#/x/server#Macros", "-debug-info-format=dwarf"])
    }

    @Test func handlesQuotes() {
        #expect(Shell.split(#"a "b c" 'd\e' "f\"g""#) == ["a", "b c", #"d\e"#, #"f"g"#])
    }
}

@Suite struct BuildLogTests {
    @Test func mapsEveryPrimaryFileOfABatchJob() {
        let log = """
            CompileSwift normal arm64 (in target 'App' from project 'App')
                /tc/usr/bin/swift-frontend -frontend -c /p/A.swift -primary-file /p/B.swift -primary-file /p/C.swift -o /o/B.o -o /o/C.o
            note: unrelated
            """
        let commands = Xcode.frontendCommands(inBuildLog: log)
        #expect(Set(commands.keys) == ["/p/B.swift", "/p/C.swift"])
        #expect(commands["/p/B.swift"]?.first == "/tc/usr/bin/swift-frontend")
    }
}

@Suite struct FrontendCommandTests {
    let command = [
        "/tc/usr/bin/swift-frontend", "-frontend", "-c", "/p/A.swift",
        "-primary-file", "/p/B.swift", "-primary-file", "/p/C.swift",
        "-emit-dependencies-path", "/o/B.d", "-serialize-diagnostics-path", "/o/B.dia",
        "-target", "arm64-apple-ios27.0-simulator", "-sdk", "/sdk",
        "-frontend-parseable-output", "-index-store-path", "/index", "-o", "/o/B.o", "-o", "/o/C.o",
    ]

    @Test func compilesOnlyTheEditedFileAndDropsBuildOutputs() {
        let patch = FrontendCommand.patch(command, primary: "/p/C.swift", output: "/tmp/C.o")
        #expect(patch == [
            "/tc/usr/bin/swift-frontend", "-frontend", "-c", "/p/A.swift",
            "/p/B.swift", "-primary-file", "/p/C.swift",
            "-target", "arm64-apple-ios27.0-simulator", "-sdk", "/sdk", "-o", "/tmp/C.o",
        ])
    }

    @Test func fileListKeepsOtherPrimaryFilesOutOfThePlainInputs() {
        // Xcode batch mode: -filelist holds every input, and the batch's files are also -primary-file.
        let batch = ["/tc/usr/bin/swift-frontend", "-frontend", "-c", "-filelist", "/o/sources",
                     "-primary-file", "/p/B.swift", "-primary-file", "/p/C.swift", "-emit-localized-strings",
                     "-emit-localized-strings-path", "/o", "-profile-generate", "-profile-coverage-mapping",
                     "-o", "/o/B.o", "-o", "/o/C.o"]
        let patch = FrontendCommand.patch(batch, primary: "/p/C.swift", output: "/tmp/C.o")
        #expect(patch == ["/tc/usr/bin/swift-frontend", "-frontend", "-c", "-filelist", "/o/sources",
                          "-primary-file", "/p/C.swift", "-o", "/tmp/C.o"])
    }

    @Test func devicePatchesCompileToIRWithoutDebugInfo() {
        let command = self.command + ["-g", "-debug-info-format=dwarf", "-dwarf-version=5"]
        let ir = FrontendCommand.patchIR(command, primary: "/p/C.swift", output: "/tmp/C.ll")
        #expect(ir.contains("-emit-ir") && !ir.contains("-c"))
        #expect(!ir.contains { $0 == "-g" || $0.hasPrefix("-debug-info-format") || $0.hasPrefix("-dwarf-version") })
        #expect(Array(ir.suffix(2)) == ["-o", "/tmp/C.ll"])
        let built = FrontendCommand.patchIR(command, primary: "/p/C.swift", source: "/s/C.swift", output: "/tmp/C0.ll")
        #expect(built.contains("/s/C.swift") && !built.contains("/p/C.swift"))
    }

    @Test func linksDevicePatchesWithTheDeviceLibraries() {
        let device = command.map { $0 == "arm64-apple-ios27.0-simulator" ? "arm64-apple-ios27.0" : $0 }
        let link = FrontendCommand.link(device, objects: ["/tmp/C.o"], output: "/tmp/patch.dylib")
        #expect(link.contains("-L/tc/usr/lib/swift/iphoneos"))
        #expect(FrontendCommand.link(command, objects: [], output: "/x").contains("-L/tc/usr/lib/swift/iphonesimulator"))
    }

    @Test func linksWithTheToolchainNextToTheFrontend() {
        let link = FrontendCommand.link(command, objects: ["/tmp/C.o"], output: "/tmp/patch.dylib")
        #expect(link.first == "/tc/usr/bin/clang")
        #expect(link.contains("-dynamiclib"))
        #expect(link.contains("dynamic_lookup"))
        #expect(link.contains("-L/sdk/usr/lib/swift"))
        #expect(Array(link[1...2]) == ["-target", "arm64-apple-ios27.0-simulator"])
    }
}

@Suite struct SessionTests {
    @Test func loadsFilesWrittenWithoutNewerKeys() throws {
        let json = #"{"bundleID":"app","commands":{"/p/A.swift":["swift-frontend"]}}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.bundleID == "app")
        #expect(session.port == 0)
        #expect(session.commands.count == 1)
    }
}

@Suite struct ReloadReportTests {
    @Test func liveSummaryNamesFileTimingAndScreen() {
        var report = ReloadReport(status: .live, files: ["/p/View.swift"])
        report.generation = 3
        report.timings.total = 512
        report.screenshot = "/s.png"
        report.visibleText = ["Today", "3 left"]
        #expect(report.summary == "swapify: View.swift is live in the running app (generation 3, 512 ms). Screenshot: /s.png. Visible text: Today | 3 left")
    }

    @Test func rebuildSummaryNamesTheTypeAndReason() {
        var report = ReloadReport(status: .needsRebuild, files: ["/p/Model.swift"])
        report.changedType = "TaskItem"
        report.reason = "stored properties changed"
        #expect(report.summary.contains("The layout of TaskItem changed (stored properties changed)"))
        #expect(report.summary.contains("swapify run"))
    }

    @Test func deviceRebuildSummaryNamesTheDeviceCommand() {
        var report = ReloadReport(status: .needsRebuild, files: ["/p/Model.swift"])
        report.rebuildCommand = "swapify run --device"
        #expect(report.summary.hasSuffix("Run `swapify run --device` to rebuild."))
    }

    @Test func headlineIsOneShortLine() {
        var live = ReloadReport(status: .live, files: ["/p/View.swift"])
        live.timings.total = 512
        #expect(live.headline == "swapify: View.swift live in 512 ms")

        var broken = ReloadReport(status: .compileError, files: ["/p/View.swift"])
        broken.errors = ["View.swift:3: error: cannot find 'x' in scope"]
        #expect(broken.headline == "swapify: View.swift does not compile, the app keeps the previous code")

        var rebuild = ReloadReport(status: .needsRebuild, files: ["/p/Model.swift"])
        rebuild.changedType = "TaskItem"
        #expect(rebuild.headline == "swapify: Model.swift needs a rebuild, the layout of TaskItem changed")
    }
}

@Suite struct SimulatorChoiceTests {
    @Test func prefersTheLastRunsSimulatorWhenBooted() {
        #expect(Simulator.choose(booted: ["B", "A"], preferred: "B") == "B")
    }

    @Test func otherwiseTakesTheFirstByUDID() {
        #expect(Simulator.choose(booted: ["B", "A"], preferred: "C") == "A")
        #expect(Simulator.choose(booted: ["B", "A"], preferred: nil) == "A")
        #expect(Simulator.choose(booted: [], preferred: "A") == nil)
    }
}
