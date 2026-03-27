import SwiftUI

struct DashboardView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    @State private var plans: [WorkoutPlan] = []
    @State private var recentSessions: [WorkoutSession] = []
    @State private var loading = true
    @State private var error: String?
    @State private var streak = 0
    @State private var weekCount = 0
    @State private var latestBodyWeight: BodyWeightEntry?
    @State private var nutritionSummary: DailySummary?
    @State private var nextDay = 1
    @State private var insights: [DashboardInsight] = []

    struct DashboardInsight: Codable, Identifiable {
        var id: String { text }
        let type: String  // "success" | "warning" | "info"
        let icon: String
        let text: String
    }

    private var todayString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView("Loading...")
                        .padding(.top, 40)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry") { Task { await loadData() } }.buttonStyle(.bordered)
                    }
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 16) {
                        // Greeting
                        greetingHeader

                        // Quick stats strip
                        statsStrip

                        // 7-day mini calendar
                        weekCalendar

                        // Insights
                        if !insights.isEmpty {
                            insightsSection
                        }

                        // Next workout
                        if let plan = plans.first {
                            NextWorkoutCard(plan: plan, nextDay: nextDay, totalDays: plan.dayCount)
                        }

                        // Today's nutrition snapshot
                        if let nutrition = nutritionSummary {
                            nutritionSnapshot(nutrition)
                        }

                        // Recent workouts
                        if !recentSessions.isEmpty {
                            recentWorkoutsSection
                        }

                        // Quick workout + Plans row
                        HStack(spacing: 12) {
                            NavigationLink {
                                ActiveWorkoutView(
                                    planId: nil,
                                    planName: "Quick Workout",
                                    dayNumber: 1
                                )
                            } label: {
                                Label("Quick Workout", systemImage: "bolt.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            NavigationLink {
                                PlansView()
                            } label: {
                                Label("Plans", systemImage: "list.bullet")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        // Quick links
                        HStack(spacing: 12) {
                            NavigationLink {
                                ProgressView_()
                            } label: {
                                quickLink(icon: "chart.line.uptrend.xyaxis", label: "Progress")
                            }
                            NavigationLink {
                                WorkoutHistoryView()
                            } label: {
                                quickLink(icon: "clock.arrow.circlepath", label: "History")
                            }
                            NavigationLink {
                                WorkoutCalendarView()
                            } label: {
                                quickLink(icon: "calendar", label: "Calendar")
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Training")
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    // MARK: - Greeting Header

    private var greetingHeader: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        let icon: String
        switch hour {
        case 5..<12:
            greeting = "Good morning"; icon = "sun.rise.fill"
        case 12..<17:
            greeting = "Good afternoon"; icon = "sun.max.fill"
        case 17..<21:
            greeting = "Good evening"; icon = "sunset.fill"
        default:
            greeting = "Good night"; icon = "moon.stars.fill"
        }
        let streakSuffix = streak > 0 ? " · \(streak) day streak 🔥" : ""
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                    Text(greeting)
                        .font(.subheadline.bold())
                }
                Text("Ready to train?\(streakSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Show today's date
            VStack(alignment: .trailing, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide)))
                    .font(.caption.bold())
                Text(Date().formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(value: "\(streak)", label: "Streak", icon: "flame.fill", color: .orange)
            Divider().frame(height: 30)
            statItem(value: "\(weekCount)", label: "This Week", icon: "calendar", color: .blue)
            Divider().frame(height: 30)
            if let bw = latestBodyWeight {
                let w = weightUnit == "lbs" ? bw.weight_kg * 2.20462 : bw.weight_kg
                statItem(value: String(format: "%.1f", w),
                         label: weightUnit, icon: "scalemass.fill", color: .green)
            } else {
                statItem(value: "—", label: "Weight", icon: "scalemass.fill", color: .green)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 7-Day Mini Calendar

    private var weekCalendar: some View {
        let cal = Calendar.current
        let today = Date()
        let days = (0..<7).map { cal.date(byAdding: .day, value: -6 + $0, to: today)! }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let completedDates = Set(recentSessions.compactMap { $0.date.map { String($0.prefix(10)) } })

        return VStack(alignment: .leading, spacing: 6) {
            Text("This Week").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let dateStr = df.string(from: day)
                    let isToday = cal.isDateInToday(day)
                    let worked  = completedDates.contains(dateStr)
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Circle()
                            .fill(worked ? Color.blue : isToday ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.15))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text("\(cal.component(.day, from: day))")
                                    .font(.caption2.bold())
                                    .foregroundStyle(worked ? .white : isToday ? .blue : .secondary)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Insights Section

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insights")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(insights.prefix(4)) { insight in
                HStack(spacing: 10) {
                    Text(insight.icon).font(.title3)
                    Text(insight.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(value).font(.title3.bold())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Nutrition Snapshot

    private func nutritionSnapshot(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today's Nutrition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(summary.totals.calories)) kcal")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            if let goals = summary.goals {
                // Progress bars toward goals
                VStack(spacing: 6) {
                    macroPill(label: "Calories", value: summary.totals.calories,
                              goal: goals.calories, unit: "kcal", color: .orange)
                    HStack(spacing: 8) {
                        macroPill(label: "Protein", value: summary.totals.protein,
                                  goal: goals.protein, unit: "g", color: .blue)
                        macroPill(label: "Carbs", value: summary.totals.carbs,
                                  goal: goals.carbs, unit: "g", color: .green)
                        macroPill(label: "Fat", value: summary.totals.fat,
                                  goal: goals.fat, unit: "g", color: .yellow)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    macroItem(label: "Cal", value: Int(summary.totals.calories), color: .orange)
                    macroItem(label: "P", value: Int(summary.totals.protein), color: .blue)
                    macroItem(label: "C", value: Int(summary.totals.carbs), color: .green)
                    macroItem(label: "F", value: Int(summary.totals.fat), color: .yellow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func macroPill(label: String, value: Double, goal: Double, unit: String, color: Color) -> some View {
        let fraction = goal > 0 ? min(value / goal, 1.0) : 0.0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))/\(Int(goal))\(unit)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15)).frame(height: 5)
                    Capsule().fill(color).frame(width: geo.size.width * fraction, height: 5)
                }
            }
            .frame(height: 5)
        }
    }

    private func macroItem(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.subheadline.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Recent Workouts

    private var recentWorkoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Workouts")
                    .font(.headline)
                Spacer()
                NavigationLink("See All") {
                    WorkoutHistoryView()
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }

            ForEach(recentSessions.prefix(5)) { session in
                NavigationLink {
                    SessionDetailView(session: session, weightUnit: weightUnit)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name ?? "Workout")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            if let date = session.date {
                                Text(formatRelativeDate(date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let sets = session.total_sets {
                                Text("\(sets) sets").font(.caption).foregroundStyle(.secondary)
                            }
                            if let vol = session.total_volume_kg, vol > 0 {
                                let disp = weightUnit == "lbs" ? vol * 2.20462 : vol
                                Text("\(Int(disp)) \(weightUnit)")
                                    .font(.caption).foregroundStyle(.blue)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Quick Links

    private func quickLink(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func formatRelativeDate(_ dateStr: String) -> String {
        let today = todayString
        if dateStr.hasPrefix(today) { return "Today" }
        // Simple relative display
        return String(dateStr.prefix(10))
    }

    private func calculateStreak(_ sessions: [WorkoutSession]) -> Int {
        let completed = sessions.filter { $0.status == "completed" }
        guard !completed.isEmpty else { return 0 }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current

        var streakCount = 0
        var checkDate = Date()

        for _ in 0..<30 {
            let dateStr = df.string(from: checkDate)
            if completed.contains(where: { $0.date?.hasPrefix(dateStr) == true }) {
                streakCount += 1
            } else if streakCount > 0 {
                break
            }
            checkDate = cal.date(byAdding: .day, value: -1, to: checkDate)!
        }
        return streakCount
    }

    private func countThisWeek(_ sessions: [WorkoutSession]) -> Int {
        let cal = Calendar.current
        let startOfWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let startStr = df.string(from: startOfWeek)

        return sessions.filter { s in
            s.status == "completed" && (s.date ?? "") >= startStr
        }.count
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            async let p: [WorkoutPlan] = APIClient.shared.get("/plans/")
            async let s: [WorkoutSession] = APIClient.shared.get("/sessions/",
                query: [.init(name: "limit", value: "30")])
            async let bw: BodyWeightEntry? = {
                let entries: [BodyWeightEntry] = try await APIClient.shared.get("/body-weight/",
                    query: [.init(name: "limit", value: "1")])
                return entries.first
            }()
            async let ns: DailySummary? = {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                return try? await APIClient.shared.get("/nutrition/summary",
                    query: [.init(name: "date", value: df.string(from: Date()))])
            }()
            async let ins: [DashboardInsight] = APIClient.shared.get("/progress/insights")

            plans = try await p
            let allSessions = try await s
            recentSessions = allSessions.filter { $0.status == "completed" }
            insights = (try? await ins) ?? []

            // Calculate next day number
            if let plan = plans.first {
                let planSessions = allSessions.filter {
                    $0.status == "completed" && $0.workout_plan_id == plan.id
                }
                let totalDays = plan.dayCount
                if totalDays > 0 {
                    nextDay = (planSessions.count % totalDays) + 1
                }
            }
            streak = calculateStreak(allSessions)
            weekCount = countThisWeek(allSessions)
            latestBodyWeight = try await bw
            nutritionSummary = try? await ns
            loading = false
        } catch {
            self.error = error.localizedDescription
            print("[Dashboard] Load error: \(error)")
            loading = false
        }
    }
}

// MARK: - Next Workout Card

struct NextWorkoutCard: View {
    let plan: WorkoutPlan
    let nextDay: Int
    let totalDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next Workout")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(plan.name)
                .font(.title3.bold())
            Text("Day \(nextDay) of \(totalDays)")
                .font(.caption)
                .foregroundStyle(.blue)

            NavigationLink("Start Workout") {
                ActiveWorkoutView(planId: plan.id, planName: plan.name, dayNumber: nextDay)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Plans List

struct PlansListView: View {
    let plans: [WorkoutPlan]

    var body: some View {
        List(plans) { plan in
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("\(plan.dayCount) days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let weeks = plan.duration_weeks {
                        Text("\(weeks) weeks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let week = plan.current_week {
                        Text("Week \(week)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Plans")
    }
}
