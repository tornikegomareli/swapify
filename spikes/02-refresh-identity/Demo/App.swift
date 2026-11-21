import SwiftUI

// Not edited during the test. It creates a Greeter with the original type.
@Observable final class Store {
    let anyGreeter: Any = Greeter()
}

@main
struct DemoApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup { ContentView(store: store) }
    }
}
