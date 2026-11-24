import SwiftUI

// `--test bind` runs Driver.swift's checks, loads tmp/patch_v2.dylib and tmp/patch_v3.dylib, and exits.
// `--test dataconst` probes whether a __DATA_CONST page can be made writable.
@main
struct BindApp: App {
    init() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--test"), i + 1 < args.count else { return }
        let test = args[i + 1]
        Thread.detachNewThread {
            spike_install_signal_handlers()
            spike_say_state()
            if test == "bind" { runBindTest() } else if test == "dataconst" { spike_dataconst_probe() }
            say("END")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup { Text("swapify spike 04") }
    }
}
