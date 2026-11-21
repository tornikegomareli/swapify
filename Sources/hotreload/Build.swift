import Foundation

/// Debug build settings that make hot reload possible. Passed on the
/// xcodebuild command line, so the project itself needs no changes.
let hotReloadSettings = [
    "ARCHS=arm64",
    "EMIT_FRONTEND_COMMAND_LINES=YES",
    "COMPILATION_CACHE_ENABLE_CACHING=NO",
    "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic",
]

func build(project: String, scheme: String) throws {
    let start = Date()
    var state = State.load()
    try FileManager.default.createDirectory(at: State.directory, withIntermediateDirectories: true)
    try compileAgent()

    let derivedData = State.directory.appendingPathComponent("DerivedData").path
    let log = State.directory.appendingPathComponent("build.log")
    let container = project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    let result = try run(["xcodebuild", container, project, "-scheme", scheme,
                          "-configuration", "Debug",
                          "-destination", "generic/platform=iOS Simulator",
                          "-derivedDataPath", derivedData]
                         + hotReloadSettings + ["build"], logFile: log)
    let output = try String(contentsOf: log, encoding: .utf8)
    guard result.status == 0 else {
        let errors = output.split(separator: "\n").filter { $0.contains("error:") }.prefix(20)
        printJSON(["ok": false, "stage": "build", "errors": errors.map(String.init), "log": log.path])
        exit(1)
    }

    // Each frontend job compiles one or more primary files.
    for line in output.split(separator: "\n") where line.contains("swift-frontend -frontend -c ") {
        let arguments = shellSplit(line.drop { $0 == " " })
        for (index, argument) in arguments.enumerated() where argument == "-primary-file" {
            state.commands[arguments[index + 1]] = arguments
        }
    }

    // Commands are printed only for files that compile, so an up-to-date
    // build with no saved state has nothing to reload with.
    guard !state.commands.isEmpty else {
        printJSON(["ok": false, "stage": "build",
                   "error": "No compile commands were captured, because the build was up to date. "
                       + "Delete \(derivedData) and run `hotreload build` again."])
        exit(1)
    }

    let products = URL(fileURLWithPath: derivedData).appendingPathComponent("Build/Products/Debug-iphonesimulator")
    guard let app = try FileManager.default.contentsOfDirectory(atPath: products.path)
        .first(where: { $0.hasSuffix(".app") }) else {
        throw CommandError(description: "No .app in \(products.path)")
    }
    let appURL = products.appendingPathComponent(app)
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
    state.appPath = appURL.path
    state.bundleID = plist?["CFBundleIdentifier"] as? String
    try state.save()
    printJSON(["ok": true, "app": appURL.path, "bundleID": state.bundleID ?? "",
               "swiftFiles": state.commands.count, "ms": milliseconds(since: start)])
}

/// Builds the in-app agent for the simulator from agent/HotAgent.m.
func compileAgent() throws {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("agent/HotAgent.m")
    let sdk = try run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let result = try run(["xcrun", "--sdk", "iphonesimulator", "clang", "-isysroot", sdk,
                          "-target", "arm64-apple-ios26.0-simulator", "-dynamiclib", "-fobjc-arc",
                          "-framework", "UIKit", source.path,
                          "-o", State.directory.appendingPathComponent("HotAgent.dylib").path])
    guard result.status == 0 else { throw CommandError(description: "Agent build failed:\n\(result.output)") }
}
