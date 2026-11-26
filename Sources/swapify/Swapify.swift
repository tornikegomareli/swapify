import ArgumentParser
import Foundation
import SwapifyCore

@main
struct Swapify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swapify",
        abstract: "Agentic hot reload for iOS apps: patch Swift edits into the running app, in the simulator or on an iPhone.",
        discussion: """
            Start with `swapify init` in your project directory, then `swapify run`. \
            After that, `swapify reload <File.swift>` makes an edit live in about a second.
            """,
        version: SwapifyInfo.version,
        subcommands: [Init.self, Run.self, Reload.self, Watch.self, UI.self, Tap.self, Screenshot.self,
                      Doctor.self, MCP.self, Hook.self]
    )
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of text.")
    var json = false
}

/// The project for commands that need one: the nearest `swapify.json` at or
/// above the current directory.
func currentWorkspace() throws -> Workspace {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    guard let workspace = Workspace.find(from: cwd) else {
        throw ValidationError("No swapify.json here or above. Run `swapify init` in your project directory.")
    }
    return workspace
}

/// The path that runs this binary, for agent configuration files.
func swapifyCommand() -> String {
    let invoked = CommandLine.arguments[0]
    if invoked.contains("/") {
        return URL(fileURLWithPath: invoked, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(directory)/\(invoked)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return invoked
}

extension Swapify {
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set up swapify in this project: swapify.json, .gitignore, the Claude Code hook, skill, and MCP server.")

        @Option(help: "The .xcworkspace or .xcodeproj, if there are several.")
        var project: String?

        @Option(help: "The app scheme, if there are several.")
        var scheme: String?

        @Flag(help: "Skip the Claude Code hook, skill, and .mcp.json.")
        var noAgents = false

        func run() throws {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let setup = Setup(root: Workspace(root: root).root, command: swapifyCommand())
            let project = try setup.project(project)
            Terminal.progress("Reading schemes of \(project)…")
            let scheme = try setup.scheme(project: project, scheme)

            print(Terminal.bold("swapify init") + Terminal.dim("  \(project) · \(scheme)"))
            Terminal.display(try setup.writeConfiguration(Configuration(project: project, scheme: scheme)))
            if let change = try setup.ignoreStateDirectory() { Terminal.display(change, note: ".swapify/") }
            if !noAgents {
                Terminal.display(try setup.installClaudeHook(), note: "reload after every Swift edit")
                Terminal.display(try setup.installSkill(try Resources.skill()))
                Terminal.display(try setup.installMCPServer(), note: "MCP tools for any agent")
            }
            print("\nNext: " + Terminal.bold("swapify run"))
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build the app with reload support and launch it in the simulator, or on an iPhone.")

        @Flag(help: "Run on the connected iPhone instead of the simulator. No debugger is attached.")
        var device = false

        @Option(help: ArgumentHelp(
            "Simulator UDID. Default: the last run's simulator if it is booted, then a booted one, then the newest iPhone.",
            discussion: "With --device: the iPhone's name or UDID, when several are connected."))
        var udid: String?

        @Option(help: "A simctl device set, for simulators outside Simulator.app.")
        var deviceSet: String?

        @Flag(help: "Launch the last build again without building.")
        var noBuild = false

        @OptionGroup var output: OutputOptions

        func run() throws {
            let workspace = try currentWorkspace()
            let launcher = Launcher(workspace: workspace)
            let configuration = try workspace.loadConfiguration()
            let target = device ? try Device.choose(Device.connected(), query: udid) : nil
            if let target, !target.developerMode { throw ValidationError(Launcher.developerModeOff(target)) }
            var build: BuildReport?
            if !noBuild {
                Terminal.progress("Building \(configuration.scheme) (Debug, reloadable\(target.map { ", for \($0.name)" } ?? ""))…")
                build = try launcher.build(device: target)
            }
            Terminal.progress(target.map { "Installing and launching on \($0.name)…" } ?? "Launching…")
            let launch = try launcher.launch(udid: device ? nil : udid, deviceSet: deviceSet, device: target)
            if output.json {
                struct RunReport: Encodable { var build: BuildReport?; var launch: LaunchReport }
                return try Terminal.json(RunReport(build: build, launch: launch))
            }
            if let build {
                print("\(Terminal.green("✓ built")) \(Terminal.bold(URL(fileURLWithPath: build.app).lastPathComponent))"
                      + Terminal.dim("  \(build.reloadableFiles) reloadable Swift files · \(build.ms / 1000) s"))
                BuildReport.notInTargetMessages(build.notInTarget).forEach { print("  " + Terminal.yellow($0)) }
            }
            let place = launch.device.map { "on \($0)" + (launch.traced == false ? ", no debugger" : "") }
                ?? "simulator \(launch.udid)"
            print("\(Terminal.green("✓ running")) \(Terminal.bold(launch.bundleID))"
                  + Terminal.dim("  \(place) · agent port \(launch.port)"))
            if let warmup = launch.warmup {
                print(warmup.status == .live
                      ? Terminal.dim("  warm-up reload passed in \(warmup.timings.total) ms")
                      : "  " + Terminal.yellow("warm-up: ") + warmup.summary)
            }
            print(Terminal.dim("  console log: \(launch.console)"))
        }
    }

    struct Reload: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Patch edited Swift files into the running app.")

        @Argument(help: "The edited Swift files.")
        var files: [String]

        @Flag(help: "Skip the screenshot and visible text.")
        var noSnapshot = false

        @OptionGroup var output: OutputOptions

        func run() throws {
            let report = try Reloader(workspace: try currentWorkspace()).reload(files: files, snapshot: !noSnapshot)
            if output.json { try Terminal.json(report) } else { Terminal.display(report) }
            if report.status != .live { throw ExitCode.failure }
        }
    }

    struct Watch: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reload Swift files when they are saved, for example by Xcode. Runs until Ctrl-C.")

        @OptionGroup var output: OutputOptions

        func run() throws {
            let workspace = try currentWorkspace()
            let session = workspace.loadSession()
            guard session.port != 0, !session.commands.isEmpty else {
                throw ValidationError("No app is running. Run `swapify run` or `swapify run --device` first.")
            }
            var watcher = Watcher(files: Array(session.commands.keys) + Array(session.borrowed.keys),
                                  root: workspace.root.path)
            Terminal.progress("Watching \(watcher.files.count) Swift files. Ctrl-C stops.")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            while true {
                let files = watcher.nextChanges()
                var report: ReloadReport
                do {
                    report = try Reloader(workspace: workspace).reload(files: files)
                } catch {
                    report = ReloadReport(status: .failed, files: files)
                    report.errors = ["\(error)"]
                }
                // JSON: one report per line.
                print(output.json ? String(decoding: try encoder.encode(report), as: UTF8.self)
                      : report.status == .live ? report.headline : report.summary)
                fflush(stdout)
            }
        }
    }

    struct UI: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ui", abstract: "List the visible accessibility elements, top to bottom.")

        @OptionGroup var output: OutputOptions

        func run() throws {
            let workspace = try currentWorkspace()
            let elements = try Agent(workspace: workspace).send("ui", as: AgentUI.self).elements ?? []
            if output.json { return try Terminal.json(elements) }
            elements.forEach { print(MCPServer.describe($0)) }
        }
    }

    struct Tap: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Activate the visible element with this accessibility label or identifier.")

        @Argument(help: "Accessibility label or identifier.")
        var label: String

        func run() throws {
            let workspace = try currentWorkspace()
            let tap = try Agent(workspace: workspace).send("tap \(label)", as: AgentTap.self)
            guard tap.ok else { throw ValidationError(tap.error ?? "The element did not respond to activation.") }
            print("\(Terminal.green("✓ tapped")) \(tap.element?.label ?? label)")
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a screenshot and print its path.")

        @Flag(help: "Capture the whole screen of the simulator or iPhone, including the status bar and system alerts.")
        var full = false

        func run() throws {
            let workspace = try currentWorkspace()
            let session = workspace.loadSession()
            let name = "screenshot-\(Int(Date().timeIntervalSince1970))"
            if full {
                guard let udid = session.udid else { throw ValidationError("No simulator yet. Run `swapify run`.") }
                try FileManager.default.createDirectory(at: workspace.screens, withIntermediateDirectories: true)
                let url = workspace.screens.appendingPathComponent(name + ".png")
                if let device = Agent(session: session).device {
                    try device.screenshot(to: url)
                } else {
                    try Simulator(deviceSet: session.deviceSet).screenshot(on: udid, to: url)
                }
                print(url.path)
            } else {
                print(try Reloader(workspace: workspace).capture(Agent(workspace: workspace), name: name))
            }
        }
    }

    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check Xcode, the project, the build, the simulator or iPhone, and the running app.")

        @OptionGroup var output: OutputOptions

        func run() throws {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let checks = SwapifyCore.Doctor(workspace: Workspace.find(from: cwd)).run()
            if output.json { return try Terminal.json(checks) }
            checks.forEach(Terminal.display)
            if checks.contains(where: { $0.status == .failure }) { throw ExitCode.failure }
        }
    }

    struct MCP: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp", abstract: "Serve the swapify tools over MCP on stdin and stdout.")

        func run() throws {
            MCPServer(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).serve()
        }
    }

    struct Hook: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Claude Code PostToolUse hook: reload the edited Swift file.", shouldDisplay: false)

        func run() throws {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
            let toolInput = event?["tool_input"] as? [String: Any]
            guard let file = toolInput?["file_path"] as? String, file.hasSuffix(".swift"),
                  let workspace = Workspace.find(from: URL(fileURLWithPath: file)) else { return }
            let session = workspace.loadSession()
            guard session.port != 0 else { return }  // never launched: stay quiet

            let message: String
            let headline: String
            do {
                let report = try Reloader(workspace: workspace).reload(files: [file])
                message = report.summary
                headline = report.status == .failed ? report.summary : report.headline
            } catch {
                message = "swapify: \(URL(fileURLWithPath: file).lastPathComponent) was not reloaded: \(error)"
                headline = message
            }
            // additionalContext goes to the model; systemMessage is the line the person sees.
            let reply: [String: Any] = [
                "systemMessage": headline,
                "hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": message],
            ]
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
