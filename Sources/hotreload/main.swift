import Foundation

let usage = """
    hotreload: live code reload into an iOS Simulator app.

    hotreload build --project <App.xcodeproj|App.xcworkspace> --scheme <Scheme>
    hotreload launch [--udid <UDID>] [--device-set <path>]
    hotreload reload <File.swift>...
    hotreload screenshot
    """

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "build":
        guard let project = option("--project", in: arguments), let scheme = option("--scheme", in: arguments) else {
            throw CommandError(description: usage)
        }
        try build(project: project, scheme: scheme)
    case "launch":
        try launchApp(udid: option("--udid", in: arguments), deviceSet: option("--device-set", in: arguments))
    case "reload" where arguments.count > 1:
        try reload(files: Array(arguments.dropFirst()))
    case "screenshot":
        let state = State.load()
        printJSON(["ok": true, "screenshot": try screenshot(state, name: "screenshot-\(Int(Date().timeIntervalSince1970))")])
    default:
        print(usage)
        exit(arguments.isEmpty ? 0 : 1)
    }
} catch {
    printJSON(["ok": false, "error": "\(error)"])
    exit(1)
}
