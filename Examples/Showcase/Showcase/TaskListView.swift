import SwiftUI
import TaskUI

struct TaskListView: View {
    let model: TaskModel

    var body: some View {
        NavigationStack {
            List {
                Section("\(model.items.filter(\.done).count) of \(model.items.count) done") {
                    ForEach(model.items) { item in
                        TaskRow(item: item) { model.toggle(item) }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar { CountBadge(remaining: model.items.filter { !$0.done }.count) }
        }
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? .green : .secondary)
                Text(item.title)
                    .strikethrough(item.done)
            }
        }
        .tint(.primary)
    }
}
