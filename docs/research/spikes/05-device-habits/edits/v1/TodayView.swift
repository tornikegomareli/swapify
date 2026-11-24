import SwiftUI

struct TodayView: View {
    let store: HabitStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProgressRing(done: store.completed, total: store.habits.count)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
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

struct ProgressRing: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 20)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : Double(done) / Double(total))
                .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(done)")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("of \(total) done")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 208, height: 208)
        .padding(.vertical, 8)
    }
}
