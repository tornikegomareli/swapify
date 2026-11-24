import SwiftUI

struct TodayView: View {
    let store: HabitStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ProgressRing(done: store.completed, total: store.habits.count)
                        .padding(.bottom, 14)
                    ForEach(store.habits) { habit in
                        Button {
                            withAnimation(.snappy) { store.toggle(habit) }
                        } label: {
                            HabitCard(habit: habit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
        }
    }
}

struct HabitCard: View {
    let habit: Habit

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: habit.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(habit.done ? Color.white : Color.primary)
                .frame(width: 46, height: 46)
                .background(habit.done ? Color.blue : Color.primary.opacity(0.06), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(habit.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                    Text("\(habit.streak) days")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: habit.done ? "checkmark.circle.fill" : "circle")
                .font(.title)
                .foregroundStyle(habit.done ? Color.blue : Color.primary.opacity(0.2))
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .contentShape(.rect(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(habit.name)
        .accessibilityValue("\(habit.streak) days" + (habit.done ? ", done" : ""))
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
