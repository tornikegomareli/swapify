import SwiftUI

class Greeter {
    func greeting() -> String { "method v2" }
}

private func helperText() -> String { "helper v2" }

struct ContentView: View {
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("body v2").font(.largeTitle).foregroundStyle(.red)
            Text(Greeter().greeting())
            Text(helperText())
            Text("tick \(tick)").monospacedDigit()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                tick += 1
            }
        }
    }
}
