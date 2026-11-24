import SwiftUI

// A second edited file with what SwiftUI code brings: an opaque `some View` body, @State, a key path
// literal, ForEach, and a generic type defined in the file.

struct Probe<T> {
    var value: T
}

struct ProbeView: View {
    @State private var count = 0
    let items = [Item(name: "p")]

    var body: some View {
        VStack {
            Text("v1 count \(count)")
            ForEach(items, id: \.name) { Text($0.greet()) }
        }
    }
}

func probeSummary() -> String {
    let path = \Box.value
    let probe = Probe(value: Box(value: 4)[keyPath: path])
    return "v1 \(probe.value) \(type(of: probe)) body: \(type(of: ProbeView().body))"
}
