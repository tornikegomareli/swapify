import SwiftUI

// v3 of App/ProbeView.swift. The body gains .padding(), so its type changes.


struct Probe<T> {
    var value: T
}

struct ProbeView: View {
    @State private var count = 0
    let items = [Item(name: "p")]

    var body: some View {
        VStack {
            Text("v3 count \(count)")
            ForEach(items, id: \.name) { Text($0.greet()) }
        }
        .padding()
        .overlay {
            Text("v3")
        }
    }
}

func probeSummary() -> String {
    let path = \Box.value
    let probe = Probe(value: Box(value: 4)[keyPath: path])
    return "v3 \(probe.value) \(type(of: probe)) body: \(type(of: ProbeView().body))"
}
