import SwiftUI

// MARK: - Dashboard Widget Identifiers

enum DashboardWidget: String, CaseIterable, Identifiable, Codable {
    case stats      = "stats"
    case calendar   = "calendar"
    case insights   = "insights"
    case nextWorkout = "nextWorkout"
    case nutrition  = "nutrition"
    case recent     = "recent"
    case quickStart = "quickStart"
    case quickLinks = "quickLinks"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stats:      return "Stats Strip"
        case .calendar:   return "Week Calendar"
        case .insights:   return "Insights"
        case .nextWorkout: return "Next Workout"
        case .nutrition:  return "Nutrition"
        case .recent:     return "Recent Workouts"
        case .quickStart: return "Quick Start"
        case .quickLinks: return "Quick Links"
        }
    }

    var icon: String {
        switch self {
        case .stats:      return "chart.bar.fill"
        case .calendar:   return "calendar"
        case .insights:   return "lightbulb.fill"
        case .nextWorkout: return "figure.strengthtraining.traditional"
        case .nutrition:  return "fork.knife"
        case .recent:     return "clock.arrow.circlepath"
        case .quickStart: return "bolt.fill"
        case .quickLinks: return "square.grid.2x2"
        }
    }
}

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
    @State private var activeSession: WorkoutSession? = nil
    private var hasActiveSession: Bool { activeSession != nil }

    // Widget ordering & visibility
    @State private var widgetOrder: [DashboardWidget] = DashboardWidget.allCases
    @State private var hiddenWidgets: Set<String> = []
    @State private var isEditing = false

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
                        // Greeting is always first, not reorderable
                        greetingHeader

                        // Active workout resume banner
                        if let session = activeSession {
                            activeWorkoutBanner(session)
                        }

                        if isEditing {
                            editModeHeader
                        }

                        // Reorderable widgets
                        ForEach(widgetOrder) { widget in
                            if !hiddenWidgets.contains(widget.rawValue) {
                                widgetView(for: widget)
                                    .overlay(alignment: .topTrailing) {
                                        if isEditing {
                                            editOverlay(for: widget)
                                        }
                                    }
                                    .opacity(isEditing ? Double(0.9) : Double(1.0))
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Training")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            if isEditing {
                                saveWidgetConfig()
                            }
                            isEditing.toggle()
                        }
                    } label: {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "square.grid.2x2")
                            .foregroundStyle(isEditing ? .green : .blue)
                    }
                }
            }
            .onAppear {
                loadWidgetConfig()
                Task { await loadData() }
            }
            .refreshable { await loadData() }
        }
    }

    // MARK: - Edit Mode

    private var editModeHeader: some View {
        VStack(spacing: 8) {
            Text("Customize Dashboard")
                .font(.subheadline.bold())
            Text("Tap arrows to reorder, tap eye to show/hide")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Show hidden widgets that can be re-enabled
            if !hiddenWidgets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hidden").font(.caption2).foregroundStyle(.secondary)
                    ForEach(DashboardWidget.allCases.filter { hiddenWidgets.contains($0.rawValue) }) { widget in
                        Button {
                            withAnimation { _ = hiddenWidgets.remove(widget.rawValue) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: widget.icon).font(.caption).frame(width: 20)
                                Text(widget.displayName).font(.caption)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func editOverlay(for widget: DashboardWidget) -> some View {
        HStack(spacing: 6) {
            // Move up
            Button {
                moveWidget(widget, direction: -1)
            } label: {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .disabled(widgetOrder.first == widget)

            // Move down
            Button {
                moveWidget(widget, direction: 1)
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .disabled(widgetOrder.last == widget)

            // Hide
            Button {
                withAnimation { _ = hiddenWidgets.insert(widget.rawValue) }
            } label: {
                Image(systemName: "eye.slash.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(4)
    }

    private func moveWidget(_ widget: DashboardWidget, direction: Int) {
        guard let idx = widgetOrder.firstIndex(of: widget) else { return }
        let newIdx = idx + direction
        guard newIdx >= 0, newIdx < widgetOrder.count else { return }
        withAnimation(.spring(duration: 0.25)) {
            widgetOrder.swapAt(idx, newIdx)
        }
    }

    // MARK: - Widget Dispatch

    @ViewBuilder
    private func widgetView(for widget: DashboardWidget) -> some View {
        switch widget {
        case .stats:
            statsStrip
        case .calendar:
            weekCalendar
        case .insights:
            if !insights.isEmpty { insightsSection }
        case .nextWorkout:
            if let plan = plans.first {
                NextWorkoutCard(plan: plan, nextDay: nextDay, totalDays: plan.dayCount, isResume: hasActiveSession)
            }
        case .nutrition:
            if let nutrition = nutritionSummary {
                nutritionSnapshot(nutrition)
            }
        case .recent:
            if !recentSessions.isEmpty { recentWorkoutsSection }
        case .quickStart:
            quickStartButtons
        case .quickLinks:
            quickLinksRow
        }
    }

    private var quickStartButtons: some View {
        HStack(spacing: 12) {
            NavigationLink {
                ActiveWorkoutView(planId: nil, planName: "Quick Workout", dayNumber: 1)
            } label: {
                Label("Quick Workout", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            NavigationLink {
                PlansView()
            } label: {
                Label("Plans", systemImage: "list.bullet").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var quickLinksRow: some View {
        HStack(spacing: 12) {
            NavigationLink { ProgressView_() } label: {
                quickLink(icon: "chart.line.uptrend.xyaxis", label: "Progress")
            }
            NavigationLink { WorkoutHistoryView() } label: {
                quickLink(icon: "clock.arrow.circlepath", label: "History")
            }
            NavigationLink { WorkoutCalendarView() } label: {
                quickLink(icon: "calendar", label: "Calendar")
            }
        }
    }

    // MARK: - Active Workout Banner

    private func activeWorkoutBanner(_ session: WorkoutSession) -> some View {
        NavigationLink {
            ActiveWorkoutView(
                planId: session.workout_plan_id,
                planName: session.name ?? "Workout",
                dayNumber: session.day_number ?? 1
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout In Progress")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(session.name ?? "Tap to resume")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
            .background(
                LinearGradient(colors: [.orange, .red],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Widget Config Persistence

    private func loadWidgetConfig() {
        if let data = UserDefaults.standard.data(forKey: "dashboardWidgetOrder"),
           let order = try? JSONDecoder().decode([DashboardWidget].self, from: data) {
            widgetOrder = order
        }
        if let data = UserDefaults.standard.data(forKey: "dashboardHiddenWidgets"),
           let hidden = try? JSONDecoder().decode(Set<String>.self, from: data) {
            hiddenWidgets = hidden
        }
    }

    private func saveWidgetConfig() {
        if let data = try? JSONEncoder().encode(widgetOrder) {
            UserDefaults.standard.set(data, forKey: "dashboardWidgetOrder")
        }
        if let data = try? JSONEncoder().encode(hiddenWidgets) {
            UserDefaults.standard.set(data, forKey: "dashboardHiddenWidgets")
        }
    }

    // MARK: - Greeting Header

    private var greetingHeader: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        let icon: String
        switch hour {
        case 5..<12:
            greeting = "Good morning"; icon = "sunrise.fill"
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
                              goal: goals.calories ?? 0, unit: "kcal", color: .orange)
                    HStack(spacing: 8) {
                        macroPill(label: "Protein", value: summary.totals.protein,
                                  goal: goals.protein ?? 0, unit: "g", color: .blue)
                        macroPill(label: "Carbs", value: summary.totals.carbs,
                                  goal: goals.carbs ?? 0, unit: "g", color: .green)
                        macroPill(label: "Fat", value: summary.totals.fat,
                                  goal: goals.fat ?? 0, unit: "g", color: .yellow)
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
        // Parallel fetch using TaskGroup — safe because @State is only
        // written AFTER all tasks complete (no async let runtime bug)
        do {
            var plansResult: [WorkoutPlan] = []
            var sessionsResult: [WorkoutSession] = []
            var bwResult: BodyWeightEntry? = nil
            var nsResult: DailySummary? = nil
            var insResult: [DashboardInsight] = []

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    plansResult = (try? await APIClient.shared.get("/plans/")) ?? []
                }
                group.addTask {
                    sessionsResult = (try? await APIClient.shared.get("/sessions/",
                        query: [.init(name: "limit", value: "30")])) ?? []
                }
                group.addTask {
                    let entries: [BodyWeightEntry]? = try? await APIClient.shared.get("/body-weight/",
                        query: [.init(name: "limit", value: "1")])
                    bwResult = entries?.first
                }
                group.addTask {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    nsResult = try? await APIClient.shared.get("/nutrition/summary",
                        query: [.init(name: "date", value: df.string(from: Date()))])
                }
                group.addTask {
                    insResult = (try? await APIClient.shared.get("/progress/insights")) ?? []
                }
            }

            // All tasks complete — now assign @State on the calling actor
            plans = plansResult
            let allSessions = sessionsResult
            recentSessions = allSessions.filter { $0.status == "completed" }
            activeSession = allSessions.first { s in
                s.status == "in_progress" || (s.started_at != nil && s.completed_at == nil)
            }
            if let plan = plansResult.first {
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
            latestBodyWeight = bwResult
            nutritionSummary = nsResult
            insights = insResult
            loading = false
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            loading = false
            print("[Dashboard] Load error: \(error)")
        }
    }
}

// MARK: - Next Workout Card

struct NextWorkoutCard: View {
    let plan: WorkoutPlan
    let nextDay: Int
    let totalDays: Int
    var isResume: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isResume ? "Active Workout" : "Next Workout")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(plan.name)
                .font(.title3.bold())
            Text("Day \(nextDay) of \(totalDays)")
                .font(.caption)
                .foregroundStyle(.blue)

            NavigationLink {
                ActiveWorkoutView(planId: plan.id, planName: plan.name, dayNumber: nextDay)
            } label: {
                Label(isResume ? "Resume Workout" : "Start Workout",
                      systemImage: isResume ? "arrow.counterclockwise" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(isResume ? .orange : .blue)
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
