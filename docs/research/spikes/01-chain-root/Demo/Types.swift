import SwiftUI

class Greeter {
    func greeting() -> String { "method v1" }
}

private func helperText() -> String { "helper v1" }

struct ContentView: View {
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("body v1").font(.largeTitle)
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
