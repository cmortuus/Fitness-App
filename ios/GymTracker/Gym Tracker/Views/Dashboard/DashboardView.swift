import SwiftUI

struct DashboardView: View {
    @State private var plans: [WorkoutPlan] = []
    @State private var recentSessions: [WorkoutSession] = []
    @State private var loading = true
    @State private var error: String?
    @State private var streak = 0
    @State private var weekCount = 0
    @State private var latestBodyWeight: BodyWeightEntry?
    @State private var nutritionSummary: DailySummary?

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
                        // Quick stats strip
                        statsStrip

                        // Next workout
                        if let plan = plans.first {
                            NextWorkoutCard(plan: plan)
                        }

                        // Today's nutrition snapshot
                        if let nutrition = nutritionSummary {
                            nutritionSnapshot(nutrition)
                        }

                        // Recent workouts
                        if !recentSessions.isEmpty {
                            recentWorkoutsSection
                        }

                        // Plans
                        NavigationLink {
                            PlansListView(plans: plans)
                        } label: {
                            Label("Manage Plans", systemImage: "list.bullet")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        // Quick links
                        HStack(spacing: 12) {
                            NavigationLink {
                                ProgressView_()
                            } label: {
                                quickLink(icon: "chart.line.uptrend.xyaxis", label: "Progress")
                            }
                            NavigationLink {
                                // Records page
                                ProgressView_()
                            } label: {
                                quickLink(icon: "trophy.fill", label: "Records")
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

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(value: "\(streak)", label: "Streak", icon: "flame.fill", color: .orange)
            Divider().frame(height: 30)
            statItem(value: "\(weekCount)", label: "This Week", icon: "calendar", color: .blue)
            Divider().frame(height: 30)
            if let bw = latestBodyWeight {
                statItem(value: String(format: "%.0f", bw.weight_kg * 2.20462),
                         label: "lbs", icon: "scalemass.fill", color: .green)
            } else {
                statItem(value: "—", label: "Weight", icon: "scalemass.fill", color: .green)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Nutrition")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                macroItem(label: "Cal", value: Int(summary.calories), color: .orange)
                macroItem(label: "P", value: Int(summary.protein), color: .red)
                macroItem(label: "C", value: Int(summary.carbs), color: .blue)
                macroItem(label: "F", value: Int(summary.fat), color: .yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            Text("Recent Workouts")
                .font(.headline)

            ForEach(recentSessions.prefix(5)) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name ?? "Workout")
                            .font(.subheadline.bold())
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
                            Text("\(Int(vol * 2.20462)) lbs")
                                .font(.caption).foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 4)
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

            plans = try await p
            let allSessions = try await s
            recentSessions = allSessions.filter { $0.status == "completed" }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next Workout")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(plan.name)
                .font(.title3.bold())

            NavigationLink("Start Workout") {
                ActiveWorkoutView(planId: plan.id, planName: plan.name)
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
