import SwiftUI

@main
struct ActivityApp: App {
    var body: some Scene {
        WindowGroup {
            ActivityView(week: .sample)
                .preferredColorScheme(.light)
        }
    }
}
