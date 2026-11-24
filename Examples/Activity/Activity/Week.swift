import Foundation

enum WeekRange: String, CaseIterable, Identifiable {
    case week, month, year

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// The palette colors in DESIGN.md.
enum Tint {
    case pink, red, orange, yellow, green, teal, blue
}

struct Day: Identifiable {
    let name: String
    let minutes: Int
    var isToday = false

    var id: String { name }
    var letter: String { String(name.prefix(1)) }
}

struct Workout: Identifiable {
    let title: String
    let day: String
    let minutes: Int
    let value: String
    let symbol: String
    let tint: Tint

    var id: String { title }
}

struct Week {
    let dates: String
    let days: [Day]
    /// The daily goal, in active minutes.
    let goal: Int
    let lastWeekMinutes: Int

    let distance: Double
    let distanceChange: Double
    let energy: Int
    let energyChange: Int
    let workouts: Int
    let workoutsChange: Int
    let heartRate: Int
    let restingHeartRate: Int

    let history: [Workout]

    var activeMinutes: Int { days.map(\.minutes).reduce(0, +) }
    var change: Int { activeMinutes - lastWeekMinutes }
}

extension Week {
    static let sample = Week(
        dates: "18 – 24 Nov",
        days: [
            Day(name: "Mon", minutes: 38),
            Day(name: "Tue", minutes: 54),
            Day(name: "Wed", minutes: 24),
            Day(name: "Thu", minutes: 40),
            Day(name: "Fri", minutes: 30),
            Day(name: "Sat", minutes: 44),
            Day(name: "Sun", minutes: 62, isToday: true),
        ],
        goal: 45,
        lastWeekMinutes: 254,
        distance: 18.4,
        distanceChange: 2.1,
        energy: 1920,
        energyChange: 240,
        workouts: 6,
        workoutsChange: 1,
        heartRate: 128,
        restingHeartRate: 56,
        history: [
            Workout(title: "Morning run", day: "Sun", minutes: 32, value: "5.2 km",
                    symbol: "figure.run", tint: .orange),
            Workout(title: "Yoga", day: "Thu", minutes: 40, value: "180 kcal",
                    symbol: "figure.mind.and.body", tint: .green),
            Workout(title: "Evening ride", day: "Tue", minutes: 54, value: "12.6 km",
                    symbol: "figure.outdoor.cycle", tint: .blue),
        ]
    )
}
