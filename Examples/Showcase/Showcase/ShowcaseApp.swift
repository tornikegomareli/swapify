import SwiftUI

@main
struct ShowcaseApp: App {
    @State private var model = TaskModel()

    var body: some Scene {
        WindowGroup {
            TaskListView(model: model)
        }
    }
}
