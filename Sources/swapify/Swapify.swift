import ArgumentParser
import Foundation
import SwapifyCore

@main
struct Swapify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swapify",
        abstract: "Agentic hot reload for iOS apps: patch Swift edits into the running simulator app.",
        discussion: """
            Start with `swapify init` in your project directory, then `swapify run`. \
            After that, `swapify reload <File.swift>` makes an edit live in about a second.
            """,
        version: SwapifyInfo.version,
        subcommands: [Init.self, Run.self, Reload.self, UI.self, Tap.self, Screenshot.self,
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
            abstract: "Build the app with reload support and launch it in the simulator.")

        @Option(help: "Simulator UDID. Default: the booted simulator, or the newest iPhone.")
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
            var build: BuildReport?
            if !noBuild {
                Terminal.progress("Building \(configuration.scheme) (Debug, reloadable)…")
                build = try launcher.build()
            }
            Terminal.progress("Launching…")
            let launch = try launcher.launch(udid: udid, deviceSet: deviceSet)
            if output.json {
                struct RunReport: Encodable { var build: BuildReport?; var launch: LaunchReport }
                return try Terminal.json(RunReport(build: build, launch: launch))
            }
            if let build {
                print("\(Terminal.green("✓ built")) \(Terminal.bold(URL(fileURLWithPath: build.app).lastPathComponent))"
                      + Terminal.dim("  \(build.reloadableFiles) reloadable Swift files · \(build.ms / 1000) s"))
            }
            print("\(Terminal.green("✓ running")) \(Terminal.bold(launch.bundleID))"
                  + Terminal.dim("  simulator \(launch.udid) · agent port \(launch.port)"))
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

    struct UI: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ui", abstract: "List the visible accessibility elements, top to bottom.")

        @OptionGroup var output: OutputOptions

        func run() throws {
            let workspace = try currentWorkspace()
            let elements = try Agent(port: workspace.loadSession().port).send("ui", as: AgentUI.self).elements ?? []
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
            let tap = try Agent(port: workspace.loadSession().port).send("tap \(label)", as: AgentTap.self)
            guard tap.ok else { throw ValidationError(tap.error ?? "The element did not respond to activation.") }
            print("\(Terminal.green("✓ tapped")) \(tap.element?.label ?? label)")
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a screenshot and print its path.")

        @Flag(help: "Capture the whole simulator screen, including the status bar and system alerts.")
        var full = false

        func run() throws {
            let workspace = try currentWorkspace()
            let session = workspace.loadSession()
            let name = "screenshot-\(Int(Date().timeIntervalSince1970))"
            if full {
                guard let udid = session.udid else { throw ValidationError("No simulator yet. Run `swapify run`.") }
                try FileManager.default.createDirectory(at: workspace.screens, withIntermediateDirectories: true)
                let url = workspace.screens.appendingPathComponent(name + ".png")
                try Simulator(deviceSet: session.deviceSet).screenshot(on: udid, to: url)
                print(url.path)
            } else {
                print(try Reloader(workspace: workspace).capture(Agent(port: session.port), name: name))
            }
        }
    }

    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check Xcode, the project, the build, and the running app.")

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
            if session.commands[URL(fileURLWithPath: file).standardizedFileURL.path] == nil {
                message = "swapify: \(URL(fileURLWithPath: file).lastPathComponent) is not part of the running app's build. "
                    + "If it is a new app file, run `swapify run` to include it."
            } else {
                do {
                    message = try Reloader(workspace: workspace).reload(files: [file]).summary
                } catch {
                    message = "swapify: \(URL(fileURLWithPath: file).lastPathComponent) was not reloaded: \(error)"
                }
            }
            let reply: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": message]]
            let data = try JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
