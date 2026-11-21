import SwiftUI

class Greeter {
    func greeting() -> String { "method v2" }
}

final class Marker {
    let value = Int.random(in: 1000...9999)
}

enum Config {
    static let marker = Marker()
}

private func helperText() -> String { "helper v2" }

// A child view defined in the edited file. Its seed changes if SwiftUI recreates it.
struct SeedView: View {
    @State private var seed = 0

    var body: some View {
        Text("child seed \(seed)")
            .onAppear { if seed == 0 { seed = Int.random(in: 1000...9999) } }
    }
}

struct ContentView: View {
    let store: Store
    @State private var seed = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("body v2").font(.largeTitle).foregroundStyle(.red)
            Text(Greeter().greeting())
            Text(helperText())
            Text("root seed \(seed)")
            SeedView()
            Text("static \(Config.marker.value)")
            Text((store.anyGreeter as? Greeter) != nil ? "cast ok" : "cast FAILED")
        }
        .onAppear { if seed == 0 { seed = Int.random(in: 1000...9999) } }
    }
}
