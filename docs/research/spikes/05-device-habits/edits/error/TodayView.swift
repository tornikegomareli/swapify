import SwiftUI

struct TodayView: View {
    let store: HabitStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ProgressRing(done: store.completed, total: store.habits.count)
                    LazyVGrid(columns: [GridItem(spacing: 12), GridItem()], spacing: 12) {
                        ForEach(store.habits) { habit in
                            Button {
                                withAnimation(.snappy) { store.toggle(habit) }
                            } label: {
                                HabitTile(habit: habit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(todayTitle)  // deliberate error: todayTitle is not defined
        }
    }
}

struct HabitTile: View {
    let habit: Habit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: habit.symbol)
                    .font(.title2.weight(.semibold))
                Spacer()
                Image(systemName: habit.done ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .opacity(habit.done ? 1 : 0.25)
            }
            Spacer(minLength: 36)
            Text(habit.name)
                .font(.title3.weight(.semibold))
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                Text("\(habit.streak) days")
                    .monospacedDigit()
            }
            .font(.subheadline.weight(.medium))
            .opacity(habit.done ? 0.9 : 0.6)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(habit.done ? Color.white : Color.primary)
        .background {
            if habit.done {
                Rectangle().fill(Color.blue.gradient)
            } else {
                Color(.secondarySystemGroupedBackground)
            }
        }
        .clipShape(.rect(cornerRadius: 28))
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
