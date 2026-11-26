import Foundation
import Observation

struct TaskItem: Identifiable {
    let id = UUID()
    var title: String
    var done = false
}

@Observable class TaskModel {
    var items: [TaskItem] = [
        TaskItem(title: "Write the agent"),
        TaskItem(title: "Patch chain roots"),
        TaskItem(title: "Refresh SwiftUI"),
    ]

    func toggle(_ item: TaskItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].done.toggle()
    }
}
