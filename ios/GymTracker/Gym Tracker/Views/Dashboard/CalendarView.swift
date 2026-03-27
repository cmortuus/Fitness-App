import SwiftUI

// MARK: - Workout Calendar View

struct WorkoutCalendarView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    @State private var sessions: [WorkoutSession] = []
    @State private var loading = true
    @State private var calYear: Int
    @State private var calMonth: Int
    @State private var selectedDay: String? = nil

    private let calendar = Calendar.current
    private static let dayNames = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    init() {
        let now = Date()
        let cal = Calendar.current
        _calYear = State(initialValue: cal.component(.year, from: now))
        _calMonth = State(initialValue: cal.component(.month, from: now) - 1) // 0-indexed
    }

    // MARK: - Computed

    private var sessionsByDate: [String: [WorkoutSession]] {
        var result: [String: [WorkoutSession]] = [:]
        for session in sessions {
            let dateStr = session.date.map { String($0.prefix(10)) } ?? ""
            if !dateStr.isEmpty {
                result[dateStr, default: []].append(session)
            }
        }
        return result
    }

    private var firstDayOfMonth: Int {
        let comps = DateComponents(year: calYear, month: calMonth + 1, day: 1)
        let date = calendar.date(from: comps)!
        return calendar.component(.weekday, from: date) - 1
    }

    private var daysInMonth: Int {
        let comps = DateComponents(year: calYear, month: calMonth + 1, day: 1)
        let date = calendar.date(from: comps)!
        return calendar.range(of: .day, in: .month, for: date)!.count
    }

    private var monthLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        let comps = DateComponents(year: calYear, month: calMonth + 1, day: 1)
        let date = calendar.date(from: comps)!
        return fmt.string(from: date)
    }

    private var todayStr: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    private func dayKey(_ d: Int) -> String {
        String(format: "%04d-%02d-%02d", calYear, calMonth + 1, d)
    }

    private var selectedSessions: [WorkoutSession] {
        guard let day = selectedDay else { return [] }
        return sessionsByDate[day] ?? []
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthNav
                dayNamesRow
                Divider()
                calendarGrid
                if let day = selectedDay {
                    sessionListForDay(day)
                } else {
                    Spacer()
                    Text("Tap a day to see workouts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.large)
            .task { await loadSessions() }
        }
    }

    // MARK: - Month Navigation

    private var monthNav: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.3)) { prevMonth() }
            } label: {
                Image(systemName: "chevron.left").font(.title3)
            }
            .padding(.leading)

            Spacer()
            Text(monthLabel)
                .font(.title3.bold())
            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) { nextMonth() }
            } label: {
                Image(systemName: "chevron.right").font(.title3)
            }
            .padding(.trailing)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Day Name Row

    private var dayNamesRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.dayNames, id: \.self) { name in
                Text(name)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        let total = firstDayOfMonth + daysInMonth
        let rows = Int(ceil(Double(total) / 7.0))

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
            ForEach(0..<rows * 7, id: \.self) { i in
                let dayNum = i - firstDayOfMonth + 1
                if dayNum < 1 || dayNum > daysInMonth {
                    Color.clear.frame(height: 44)
                } else {
                    let key = dayKey(dayNum)
                    let sessionCount = sessionsByDate[key]?.count ?? 0
                    let isToday = key == todayStr
                    let isSelected = key == selectedDay

                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedDay = selectedDay == key ? nil : key
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.blue : isToday ? Color.blue.opacity(0.15) : Color.clear)
                                .frame(height: 44)

                            VStack(spacing: 2) {
                                Text("\(dayNum)")
                                    .font(isToday ? .subheadline.bold() : .subheadline)
                                    .foregroundStyle(isSelected ? .white : isToday ? .blue : .primary)

                                if sessionCount > 0 {
                                    HStack(spacing: 2) {
                                        ForEach(0..<min(sessionCount, 3), id: \.self) { _ in
                                            Circle()
                                                .fill(isSelected ? Color.white.opacity(0.9) : Color.blue)
                                                .frame(width: 4, height: 4)
                                        }
                                    }
                                } else {
                                    Color.clear.frame(height: 6)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }

    // MARK: - Session List for Selected Day

    private func sessionListForDay(_ day: String) -> some View {
        let daySessions = sessionsByDate[day] ?? []
        return Group {
            if daySessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Rest day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(daySessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session, weightUnit: weightUnit)
                    } label: {
                        sessionRow(session)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "dumbbell.fill")
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? "Workout")
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    if let sets = session.total_sets {
                        Text("\(sets) sets").font(.caption).foregroundStyle(.secondary)
                    }
                    if let vol = session.total_volume_kg, vol > 0 {
                        let disp = weightUnit == "lbs" ? vol * 2.20462 : vol
                        Text("· \(Int(disp)) \(weightUnit)").font(.caption).foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            if let started = session.started_at, let completed = session.completed_at {
                let mins = durationMinutes(from: started, to: completed)
                Text(formatMins(mins))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Navigation

    private func prevMonth() {
        if calMonth == 0 {
            calMonth = 11
            calYear -= 1
        } else {
            calMonth -= 1
        }
    }

    private func nextMonth() {
        if calMonth == 11 {
            calMonth = 0
            calYear += 1
        } else {
            calMonth += 1
        }
    }

    // MARK: - Data Loading

    private func loadSessions() async {
        do {
            sessions = try await APIClient.shared.get("/sessions/",
                query: [
                    .init(name: "limit", value: "500"),
                    .init(name: "status", value: "completed"),
                ])
            loading = false
        } catch {
            print("[Calendar] Load error: \(error)")
            loading = false
        }
    }

    // MARK: - Helpers

    private func durationMinutes(from: String, to: String) -> Int {
        let df = ISO8601DateFormatter()
        guard let start = df.date(from: from), let end = df.date(from: to) else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private func formatMins(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }
}
