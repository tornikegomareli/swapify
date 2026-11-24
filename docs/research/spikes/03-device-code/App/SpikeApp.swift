import SwiftUI

// `--test <name>` runs one test from Tests.c on a background thread and exits with its result.
// `serve` keeps running. The buttons run the same tests by hand.
@main
struct SpikeApp: App {
    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test"), i + 1 < args.count {
            Runner.start(args[i + 1], exitWhenDone: args[i + 1] != "serve")
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Runner {
    static func start(_ name: String, exitWhenDone: Bool) {
        let thread = Thread {
            let rc = spike_run(name)
            if exitWhenDone { exit(rc) }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

struct ContentView: View {
    private let tests = ["1a", "1b", "1c", "1d", "1e", "3tmp", "3lib", "3dylib", "3adhoc", "3otherteam", "3bundle",
                         "serve"]

    var body: some View {
        NavigationStack {
            List(tests, id: \.self) { name in
                Button("Run \(name)") { Runner.start(name, exitWhenDone: false) }
            }
            .navigationTitle("swapify spike 03")
        }
        // Keeps the screen from auto-locking while this app is frontmost (transport tests).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}
