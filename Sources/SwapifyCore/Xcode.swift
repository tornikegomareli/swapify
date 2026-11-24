import Foundation

public enum Xcode {
    /// Debug build settings that make an app reloadable. They are passed on the
    /// xcodebuild command line, so the project itself needs no changes.
    public static let reloadSettings = [
        // One architecture: the simulator runs the host's.
        "ARCHS=arm64",
        // Prints every swift-frontend command into the build log.
        "EMIT_FRONTEND_COMMAND_LINES=YES",
        // Cached builds refer to llvmcas:// inputs, which a single-file compile cannot use.
        "COMPILATION_CACHE_ENABLE_CACHING=NO",
        // Every function reads its dynamic replacement chain root first.
        "OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -enable-implicit-dynamic",
    ]

    /// A device build also exports every declaration, `private` ones included, so a
    /// patch can bind to the app's types instead of patching code. See
    /// docs/architecture.md, "On a device".
    public static let deviceReloadSettings = reloadSettings.map {
        $0.hasPrefix("OTHER_SWIFT_FLAGS=") ? $0 + " -Xfrontend -enable-private-imports" : $0
    }

    /// Xcode projects and workspaces directly in `directory`, workspaces first.
    public static func projects(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }.sorted()
        let projects = names.filter { $0.hasSuffix(".xcodeproj") }.sorted()
        return workspaces + projects
    }

    public static func schemes(project: URL) throws -> [String] {
        let flag = project.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let result = try Shell.run(["xcodebuild", "-list", "-json", flag, project.path])
        guard result.succeeded, let start = result.output.firstIndex(of: "{") else {
            throw SwapifyError("xcodebuild -list failed for \(project.path):\n\(result.output)")
        }
        let json = try JSONSerialization.jsonObject(with: Data(result.output[start...].utf8)) as? [String: Any]
        let container = (json?["workspace"] ?? json?["project"]) as? [String: Any]
        return container?["schemes"] as? [String] ?? []
    }

    /// Builds for the simulator, or for the device with that UDID with the project's
    /// own signing. Like Xcode, a device build may update provisioning profiles and
    /// register the device with the team.
    public static func build(project: URL, scheme: String, derivedData: URL, log: URL,
                             device: String? = nil) throws -> ProcessResult {
        let flag = project.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let destination = device.map { ["-destination", "id=\($0)", "-allowProvisioningUpdates",
                                         "-allowProvisioningDeviceRegistration"] + deviceReloadSettings }
            ?? ["-destination", "generic/platform=iOS Simulator"] + reloadSettings
        return try Shell.run(
            ["xcodebuild", flag, project.path, "-scheme", scheme, "-configuration", "Debug",
             "-derivedDataPath", derivedData.path] + destination + ["build"],
            log: log)
    }

    /// A clear message for the build failures that device builds add.
    public static func signingProblem(inBuildLog log: String) -> String? {
        guard log.contains("requires a development team") else { return nil }
        return "The project has no signing team, which a device build needs. In Xcode, select the app target, "
            + "open Signing & Capabilities, and pick a Team. Then run `swapify run --device` again."
    }

    /// Source path -> frontend command, for each file the build compiled. A
    /// batch job compiles several primary files with one command.
    public static func frontendCommands(inBuildLog log: String) -> [String: [String]] {
        var commands: [String: [String]] = [:]
        for line in log.split(separator: "\n") where line.contains("swift-frontend -frontend -c ") {
            let arguments = Shell.split(line.drop { $0 == " " })
            for (index, argument) in arguments.enumerated()
            where argument == "-primary-file" && index + 1 < arguments.count {
                commands[arguments[index + 1]] = arguments
            }
        }
        return commands
    }

    public static func errors(inBuildLog log: String) -> [String] {
        log.split(separator: "\n").filter { $0.contains("error:") }.prefix(30).map(String.init)
    }

    /// The most recently built app in the simulator products directory, or the device one.
    public static func builtApp(derivedData: URL, device: Bool = false) throws -> (path: URL, bundleID: String) {
        let products = derivedData.appendingPathComponent(device ? "Build/Products/Debug-iphoneos"
                                                                 : "Build/Products/Debug-iphonesimulator")
        let apps = ((try? FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "app" }
        let newest = apps.max { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA < dateB
        }
        guard let app = newest else { throw SwapifyError("The build produced no .app in \(products.path)") }
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        guard let bundleID = plist?["CFBundleIdentifier"] as? String else {
            throw SwapifyError("\(app.lastPathComponent) has no CFBundleIdentifier")
        }
        return (app, bundleID)
    }
}
