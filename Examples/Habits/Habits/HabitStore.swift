import Foundation
import Observation

struct Habit: Identifiable {
    let id = UUID()
    var name: String
    var symbol: String
    var streak: Int
    var done = false
}

@Observable final class HabitStore {
    var habits = [
        Habit(name: "Run", symbol: "figure.run", streak: 12),
        Habit(name: "Read", symbol: "book", streak: 4),
        Habit(name: "Meditate", symbol: "leaf", streak: 27),
        Habit(name: "Water", symbol: "drop", streak: 9),
    ]

    var completed: Int { habits.filter(\.done).count }

    func toggle(_ habit: Habit) {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[index].done.toggle()
    }
}
