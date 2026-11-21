import SwiftUI

struct TodayView: View {
    let store: HabitStore

    var body: some View {
        NavigationStack {
            List {
                Text("\(store.completed) of \(store.habits.count) done")
                ForEach(store.habits) { habit in
                    HStack {
                        Image(systemName: habit.symbol)
                        Text(habit.name)
                        Spacer()
                        Text("\(habit.streak) days")
                    }
                }
            }
            .navigationTitle("Today")
        }
    }
}
