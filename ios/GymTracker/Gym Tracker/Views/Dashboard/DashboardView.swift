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

    // 1RM calculator
    @State private var calcWeight: Double? = nil
    @State private var calcReps: Int? = nil

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

    // Computed stats
    private var weeklySets: Int {
        recentSessions.compactMap(\.total_sets).reduce(0, +)
    }
    private var weeklyVolume: Double {
        let vol = recentSessions.compactMap(\.total_volume_kg).reduce(0, +)
        return weightUnit == "lbs" ? vol * 2.20462 : vol
    }
    private var weeklyVolumeFormatted: String {
        weeklyVolume >= 1000 ? String(format: "%.1fk", weeklyVolume / 1000) : "\(Int(weeklyVolume))"
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
                    VStack(spacing: 20) {
                        // 1. Quick Stats Bar (4 columns)
                        quickStatsBar

                        // 2. Next Workout Card
                        if let plan = plans.first {
                            nextWorkoutHero(plan: plan)
                        }

                        // 3. Active Workout Banner (if in progress)
                        if let session = activeSession {
                            activeWorkoutBanner(session)
                        }

                        // 4. Manage Plans Row
                        managePlansRow

                        // 5. This Week Calendar
                        weekCalendar

                        // 6. Training Log
                        trainingLogSection

                        // 7. Repeat Last Workout (#475)
                        if let lastSession = recentSessions.first {
                            repeatLastWorkoutButton(lastSession)
                        }

                        // 8. Insights
                        if !insights.isEmpty {
                            insightsSection
                        }

                        // 9. Nutrition
                        if let ns = nutritionSummary {
                            nutritionSnapshot(ns)
                        }

                        // 10. Inline 1RM Calculator (#476)
                        inlineCalculator
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
            }
            .background(AppColors.zinc950)
            .navigationTitle("GymTracker")
            .navigationBarTitleDisplayMode(.large)
            .task {
                loadWidgetConfig()
                await loadData()
            }
            .refreshable { await loadData() }
        }
    }

    // MARK: - Quick Stats Bar

    private var quickStatsBar: some View {
        HStack(spacing: 8) {
            statBox(value: "\(weekCount)", label: "workouts", color: AppColors.primary)
            statBox(value: "\(weeklySets)", label: "sets", color: .green)
            statBox(value: weeklyVolumeFormatted, label: weightUnit, color: AppColors.accent)
            statBox(value: "\(streak)", label: "streak", color: .yellow)
        }
    }

    private func statBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppColors.zinc500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(AppColors.zinc800, lineWidth: 1)
        )
    }

    // MARK: - Next Workout Hero

    private func nextWorkoutHero(plan: WorkoutPlan) -> some View {
        let day = plan.days?[safe: nextDay - 1]
        let dayName = day?.day_name ?? "Day \(nextDay)"
        let exerciseCount = day?.exercises.count ?? 0

        return NavigationLink {
            ActiveWorkoutView(planId: plan.id, planName: plan.name, dayNumber: nextDay)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXT · \(plan.name.uppercased())")
                        .font(.caption2.bold())
                        .tracking(1.2)
                        .foregroundStyle(AppColors.primary)

                    Text(dayName)
                        .font(.title.bold())
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Text("Week \(plan.current_week ?? 1)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppColors.primary.opacity(0.15))
                            .foregroundStyle(AppColors.primary)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(AppColors.primary.opacity(0.3), lineWidth: 1))

                        Text("Day \(nextDay)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppColors.zinc800)
                            .foregroundStyle(AppColors.zinc300)
                            .clipShape(Capsule())

                        Text("\(exerciseCount) exercises")
                            .font(.caption2)
                            .foregroundStyle(AppColors.zinc500)
                    }
                }

                Spacer()

                Text("🏋️")
                    .font(.system(size: 28))
                    .frame(width: 56, height: 56)
                    .background(AppColors.primary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(AppColors.primary.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [AppColors.primary.opacity(0.12), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppColors.primary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Manage Plans Row

    // MARK: - Repeat Last Workout (#475)

    private func repeatLastWorkoutButton(_ session: WorkoutSession) -> some View {
        NavigationLink {
            ActiveWorkoutView(
                planId: session.workout_plan_id,
                planName: session.name ?? "Workout",
                dayNumber: session.day_number ?? 1
            )
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
                    .foregroundStyle(AppColors.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repeat Last Workout")
                        .font(.subheadline.bold())
                        .foregroundStyle(AppColors.zinc300)
                    Text(session.name ?? "Workout")
                        .font(.caption2)
                        .foregroundStyle(AppColors.zinc500)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.zinc600)
            }
            .padding()
            .background(AppColors.zinc900)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppColors.zinc800, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 1RM Calculator (#476)

    private var inlineCalculator: some View {
        let oneRM: Double? = {
            guard let w = calcWeight, let r = calcReps, w > 0, r > 0 else { return nil }
            return w * (1 + Double(r) / 30)
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("1RM Calculator")
                .font(.subheadline.bold())
            HStack(spacing: 12) {
                HStack {
                    TextField("Weight", value: $calcWeight, format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    Text(weightUnit).font(.caption).foregroundStyle(AppColors.zinc500)
                }
                HStack {
                    TextField("Reps", value: $calcReps, format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Text("reps").font(.caption).foregroundStyle(AppColors.zinc500)
                }
            }
            if let rm = oneRM {
                HStack {
                    Text("Estimated 1RM:")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.zinc400)
                    Text("\(Int(rm)) \(weightUnit)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(AppColors.primary)
                }
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    private var managePlansRow: some View {
        NavigationLink {
            PlansView()
        } label: {
            HStack(spacing: 12) {
                Text("📋")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage Plans")
                        .font(.subheadline.bold())
                        .foregroundStyle(AppColors.zinc300)
                    Text("Create, edit, and archive workout plans")
                        .font(.caption2)
                        .foregroundStyle(AppColors.zinc500)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppColors.zinc600)
            }
            .padding()
            .background(AppColors.zinc900)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppColors.zinc800, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Training Log Section

    private var trainingLogSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Training Log")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    WorkoutHistoryView()
                } label: {
                    Text("Full Calendar →")
                        .font(.caption)
                        .foregroundStyle(AppColors.primary)
                }
            }

            // 3 stat boxes
            HStack(spacing: 8) {
                logStatBox(value: "\(streak)", label: "Day Streak", color: AppColors.primary)
                logStatBox(value: "\(weekCount)", label: "This Week", color: .green)
                logStatBox(value: "\(weeklyVolumeFormatted)", label: "\(weightUnit) this wk", color: .yellow)
            }

            // Recent sessions
            VStack(spacing: 0) {
                ForEach(recentSessions.prefix(5)) { session in
                    HStack {
                        Text(session.name ?? "Workout")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(session.date ?? "")
                            .font(.caption)
                            .foregroundStyle(AppColors.zinc500)
                    }
                    .padding(.vertical, 8)
                    if session.id != recentSessions.prefix(5).last?.id {
                        Divider().background(AppColors.zinc800)
                    }
                }
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(AppColors.zinc800, lineWidth: 1)
        )
    }

    private func logStatBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppColors.zinc500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppColors.zinc800.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                            .clipShape(RoundedRectangle(cornerRadius: 16))
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
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                LinearGradient(colors: [AppColors.primary.opacity(0.2), AppColors.primary.opacity(0.05)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(AppColors.primary.opacity(0.3), lineWidth: 1)
            )
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
        .background(AppColors.zinc900)
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
        .background(AppColors.zinc900)
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
        .background(AppColors.zinc900)
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
        .background(AppColors.zinc900)
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
        .background(AppColors.zinc900)
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

    private enum DashResult: Sendable {
        case plans([WorkoutPlan])
        case sessions([WorkoutSession])
        case bodyWeight(BodyWeightEntry?)
        case nutrition(DailySummary?)
        case insights([DashboardInsight])
    }

    private func loadData() async {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: Date())

        let results = await withTaskGroup(of: DashResult.self, returning: [DashResult].self) { group in
            group.addTask { .plans((try? await APIClient.shared.get("/plans/")) ?? []) }
            group.addTask { .sessions((try? await APIClient.shared.get("/sessions/", query: [.init(name: "limit", value: "30")])) ?? []) }
            group.addTask {
                let entries: [BodyWeightEntry] = (try? await APIClient.shared.get("/body-weight/", query: [.init(name: "limit", value: "1")])) ?? []
                return .bodyWeight(entries.first)
            }
            group.addTask { .nutrition(try? await APIClient.shared.get("/nutrition/summary", query: [.init(name: "date", value: todayStr)])) }
            group.addTask { .insights((try? await APIClient.shared.get("/progress/insights")) ?? []) }

            var collected: [DashResult] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Unpack results and assign @State
        var allSessions: [WorkoutSession] = []
        for result in results {
            switch result {
            case .plans(let p): plans = p
            case .sessions(let s): allSessions = s
            case .bodyWeight(let bw): latestBodyWeight = bw
            case .nutrition(let ns): nutritionSummary = ns
            case .insights(let ins): insights = ins
            }
        }

        recentSessions = allSessions.filter { $0.status == "completed" }
        activeSession = allSessions.first { s in
            s.status == "in_progress" || (s.started_at != nil && s.completed_at == nil)
        }
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

        // If ALL data is empty, API might be failing — check auth
        if plans.isEmpty && allSessions.isEmpty && latestBodyWeight == nil && nutritionSummary == nil {
            // Try a simple auth check
            do {
                let _: [WorkoutPlan] = try await APIClient.shared.get("/plans/")
            } catch {
                if case APIError.unauthorized = error {
                    await AuthService.shared.logout()
                    return
                }
                self.error = "Unable to connect. Pull down to retry."
            }
        }

        loading = false
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
        .background(AppColors.zinc900)
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
