import SwiftUI
import Charts

struct ProgressView_: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    // Data
    @State private var dataPoints: [ProgressDataPoint] = []
    @State private var recommendations: [ProgressRecommendation] = []
    @State private var bodyWeights: [BodyWeightEntry] = []
    @State private var personalRecords: [PersonalRecord] = []
    @State private var volumeLandmarks: [VolumeLandmark] = []
    @State private var allExerciseNames: [String] = []
    @State private var loading = true
    @State private var showAllRecords = false
    @State private var showCalculator = false

    // Filters
    @State private var timeRange: Int = 30           // days
    @State private var selectedExercise: String = "All"
    @State private var chartMode: ChartMode = .oneRM

    enum ChartMode: String, CaseIterable {
        case oneRM   = "1RM"
        case volume  = "Volume"
        case bodyWeight = "Weight"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                ScrollView {
                    if loading {
                        ProgressView().padding(.top, 60)
                    } else {
                        VStack(spacing: 20) {
                            mainChart
                            recommendationsSection
                            if !personalRecords.isEmpty {
                                personalRecordsSection
                            }
                            muscleGroupSection
                            sessionLogSection
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Progress")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCalculator = true
                    } label: {
                        Image(systemName: "function")
                    }
                }
            }
            .sheet(isPresented: $showCalculator) {
                CalculatorView()
            }
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Time range
                Picker("Time", selection: $timeRange) {
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .onChange(of: timeRange) { _, _ in Task { await loadData() } }

                // Exercise filter
                Menu {
                    Button("All Exercises") { selectedExercise = "All" }
                    ForEach(allExerciseNames, id: \.self) { name in
                        Button(name) { selectedExercise = name }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedExercise == "All" ? "All Exercises" : selectedExercise)
                            .lineLimit(1)
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)

            // Chart mode tabs
            Picker("Chart Mode", selection: $chartMode) {
                ForEach(ChartMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Filtered Data

    private var filteredPoints: [ProgressDataPoint] {
        if selectedExercise == "All" { return dataPoints }
        return dataPoints.filter { $0.exercise_name == selectedExercise }
    }

    /// Group points by exercise name → [(name, [points])]
    private var groupedByExercise: [(String, [ProgressDataPoint])] {
        var dict: [String: [ProgressDataPoint]] = [:]
        for p in filteredPoints {
            dict[p.exercise_name, default: []].append(p)
        }
        return dict.map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Main Chart

    @ViewBuilder
    private var mainChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chartMode.rawValue + " Trend")
                .font(.headline)

            if filteredPoints.isEmpty {
                emptyState("No data for this period. Complete some workouts!")
            } else {
                switch chartMode {
                case .oneRM:    oneRMLineChart
                case .volume:   volumeBarChart
                case .bodyWeight: bodyWeightLineChart
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var oneRMLineChart: some View {
        let groups = groupedByExercise
        return Chart {
            ForEach(groups, id: \.0) { name, points in
                ForEach(points) { p in
                    if let rm = p.estimated_1rm {
                        LineMark(
                            x: .value("Date", p.date),
                            y: .value("1RM", displayWeight(rm))
                        )
                        .foregroundStyle(by: .value("Exercise", name))
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Date", p.date),
                            y: .value("1RM", displayWeight(rm))
                        )
                        .foregroundStyle(by: .value("Exercise", name))
                        .symbolSize(30)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
        .chartYAxisLabel("Est. 1RM (\(weightUnit))")
        .frame(height: 220)
        .chartLegend(groups.count <= 6 ? .automatic : .hidden)
    }

    private var volumeBarChart: some View {
        let groups = groupedByExercise
        return Chart {
            ForEach(groups, id: \.0) { name, points in
                ForEach(points) { p in
                    if let vol = p.volume_load {
                        BarMark(
                            x: .value("Date", p.date),
                            y: .value("Volume", displayWeight(vol))
                        )
                        .foregroundStyle(by: .value("Exercise", name))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
            }
        }
        .chartYAxisLabel("Volume (\(weightUnit))")
        .frame(height: 220)
        .chartLegend(groups.count <= 6 ? .automatic : .hidden)
    }

    private var bodyWeightLineChart: some View {
        Chart(bodyWeights.reversed()) { entry in
            LineMark(
                x: .value("Date", String(entry.recorded_at?.prefix(10) ?? "")),
                y: .value("Weight", displayWeight(entry.weight_kg))
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.blue)
            PointMark(
                x: .value("Date", String(entry.recorded_at?.prefix(10) ?? "")),
                y: .value("Weight", displayWeight(entry.weight_kg))
            )
            .foregroundStyle(.blue)
            .symbolSize(30)
        }
        .chartYAxisLabel(weightUnit)
        .frame(height: 220)
    }

    // MARK: - Recommendations Section

    @ViewBuilder
    private var recommendationsSection: some View {
        let recs = selectedExercise == "All"
            ? recommendations
            : recommendations.filter { $0.exercise_name == selectedExercise }

        if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Progression Recommendations")
                    .font(.headline)
                ForEach(recs) { rec in
                    recommendationRow(rec)
                }
            }
            .padding()
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func recommendationRow(_ rec: ProgressRecommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.exercise_name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let reason = rec.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let cur = rec.current_weight {
                    Text(String(format: "%.0f %@", displayWeight(cur), weightUnit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let rec_w = rec.recommended_weight {
                    let delta = (rec.current_weight.map { rec_w - $0 } ?? 0)
                    HStack(spacing: 2) {
                        Image(systemName: delta > 0.5 ? "arrow.up" : delta < -0.5 ? "arrow.down" : "arrow.right")
                            .font(.caption)
                        Text(String(format: "%.0f %@", displayWeight(rec_w), weightUnit))
                            .font(.subheadline.bold())
                    }
                    .foregroundStyle(delta > 0.5 ? .green : delta < -0.5 ? .red : .primary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Personal Records Section

    private var personalRecordsSection: some View {
        let filtered = selectedExercise == "All"
            ? personalRecords
            : personalRecords.filter { $0.exerciseName == selectedExercise }
        let shown = showAllRecords ? filtered : Array(filtered.prefix(5))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personal Records")
                    .font(.headline)
                Spacer()
                Image(systemName: "trophy.fill")
                    .foregroundStyle(.yellow)
            }

            ForEach(shown) { pr in
                prRow(pr)
                if pr.id != shown.last?.id {
                    Divider()
                }
            }

            if filtered.count > 5 {
                Button {
                    withAnimation { showAllRecords.toggle() }
                } label: {
                    Text(showAllRecords ? "Show Less" : "Show All \(filtered.count) Records")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func prRow(_ pr: PersonalRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(pr.exerciseName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let reps = pr.best_set_reps, let w = pr.best_set_weight_kg, w > 0 {
                    Text("\(Int(displayWeight(w))) \(weightUnit) × \(reps) reps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let rm = pr.best_1rm_kg {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f %@", displayWeight(rm), weightUnit))
                        .font(.subheadline.bold())
                        .foregroundStyle(.yellow)
                    Text("est. 1RM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Muscle Group / Volume Section

    @ViewBuilder
    private var muscleGroupSection: some View {
        let active = volumeLandmarks.filter { $0.sets > 0 }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Weekly Volume")
                        .font(.headline)
                    Spacer()
                    Text("MEV/MAV/MRV")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(active) { landmark in
                    volumeLandmarkRow(landmark)
                }

                if active.count < volumeLandmarks.count {
                    Text("\(volumeLandmarks.count - active.count) muscles with 0 sets this period")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func volumeLandmarkRow(_ lm: VolumeLandmark) -> some View {
        let barFraction = min(1.0, Double(lm.sets) / Double(max(lm.mrv, 1)))
        let color: Color = {
            switch lm.status {
            case "in_range": return .green
            case "above_mav": return .orange
            case "above_mrv": return .red
            case "below_mev": return .red.opacity(0.7)
            default: return .secondary
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lm.muscle.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                Text("\(lm.sets) sets")
                    .font(.caption)
                    .foregroundStyle(color)
                    .bold()
            }
            // Progress bar with MEV/MAV markers
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * barFraction, height: 6)
                    // MEV marker
                    let mevX = geo.size.width * Double(lm.mev) / Double(max(lm.mrv, 1))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: mevX, y: -2)
                    // MAV marker
                    let mavX = geo.size.width * Double(lm.mav) / Double(max(lm.mrv, 1))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 1, height: 10)
                        .offset(x: mavX, y: -2)
                }
            }
            .frame(height: 8)
        }
    }

    // Kept for backward compat — no longer used (replaced by volumeLandmarks)
    private func muscleGroupTrends() -> [(String, Double, Int)] {
        // Group points by exercise, compute % change from first to last
        var byExercise: [String: [ProgressDataPoint]] = [:]
        for p in filteredPoints {
            byExercise[p.exercise_name, default: []].append(p)
        }

        // We don't have muscle group data here — derive from exercise name heuristics
        // (proper solution would join with exercise metadata)
        var groupChanges: [String: [Double]] = [:]
        for (_, points) in byExercise {
            let sorted = points.sorted { $0.date < $1.date }
            guard let first = sorted.first?.estimated_1rm,
                  let last  = sorted.last?.estimated_1rm,
                  first > 0, sorted.count >= 2 else { continue }
            let pctChange = (last - first) / first * 100

            // Muscle group from exercise name heuristics
            let name = (sorted.first?.exercise_name ?? "").lowercased()
            let group: String
            if name.contains("squat") || name.contains("leg press") || name.contains("lunge") || name.contains("hip thrust") {
                group = "Legs"
            } else if name.contains("bench") || name.contains("chest") || name.contains("fly") || name.contains("push") {
                group = "Chest"
            } else if name.contains("row") || name.contains("pull") || name.contains("lat") || name.contains("back") {
                group = "Back"
            } else if name.contains("shoulder") || name.contains("press") || name.contains("lateral") || name.contains("delt") {
                group = "Shoulders"
            } else if name.contains("curl") || name.contains("bicep") || name.contains("hammer") {
                group = "Biceps"
            } else if name.contains("tricep") || name.contains("dip") || name.contains("extension") {
                group = "Triceps"
            } else if name.contains("calf") || name.contains("deadlift") || name.contains("rdl") {
                group = "Posterior Chain"
            } else {
                group = "Other"
            }
            groupChanges[group, default: []].append(pctChange)
        }

        return groupChanges.map { group, changes in
            let avg = changes.reduce(0, +) / Double(changes.count)
            return (group, avg, changes.count)
        }
        .sorted { $0.0 < $1.0 }
    }

    // MARK: - Session Log Section

    private var sessionLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Log")
                .font(.headline)

            let points = filteredPoints.sorted { $0.date > $1.date }
            if points.isEmpty {
                emptyState("No sessions in this period.")
                    .padding(.vertical, 8)
            } else {
                ForEach(points.prefix(50)) { p in
                    sessionLogRow(p)
                    Divider()
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sessionLogRow(_ p: ProgressDataPoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.exercise_name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(formatDate(p.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let rm = p.estimated_1rm {
                    Text(String(format: "%.0f %@ 1RM", displayWeight(rm), weightUnit))
                        .font(.subheadline.bold())
                }
                if let vol = p.volume_load {
                    Text(String(format: "%.0f %@ vol", displayWeight(vol), weightUnit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func displayWeight(_ kg: Double) -> Double {
        weightUnit == "lbs" ? kg * 2.20462 : kg
    }

    private func formatDate(_ str: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let d = df.date(from: str) {
            let out = DateFormatter()
            out.dateStyle = .medium
            return out.string(from: d)
        }
        return str
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Data Loading

    private func loadData() async {
        loading = true

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -timeRange, to: endDate)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let startStr = fmt.string(from: startDate)
        let endStr   = fmt.string(from: endDate)

        enum ProgResult: Sendable {
            case points([ProgressDataPoint])
            case recs([ProgressRecommendation])
            case bw([BodyWeightEntry])
            case prs([PersonalRecord])
            case vol(VolumeLandmarksResponse?)
        }

        let results = await withTaskGroup(of: ProgResult.self, returning: [ProgResult].self) { group in
            group.addTask { .points((try? await APIClient.shared.get("/progress/", query: [.init(name: "start_date", value: startStr), .init(name: "end_date", value: endStr)])) ?? []) }
            group.addTask { .recs((try? await APIClient.shared.get("/progress/recommendations", query: [.init(name: "days_back", value: "\(timeRange)")])) ?? []) }
            group.addTask { .bw((try? await APIClient.shared.get("/body-weight/", query: [.init(name: "limit", value: "90")])) ?? []) }
            group.addTask { .prs((try? await APIClient.shared.get("/progress/records")) ?? []) }
            group.addTask { .vol(try? await APIClient.shared.get("/progress/volume-landmarks", query: [.init(name: "days", value: "\(timeRange)")])) }

            var collected: [ProgResult] = []
            for await r in group { collected.append(r) }
            return collected
        }

        var pts2: [ProgressDataPoint] = []
        for result in results {
            switch result {
            case .points(let p): pts2 = p; dataPoints = p
            case .recs(let r): recommendations = r
            case .bw(let b): bodyWeights = b
            case .prs(let p): personalRecords = p
            case .vol(let v): volumeLandmarks = v?.muscles ?? [:]
            }
        }

        let names = Set(pts2.map { $0.exercise_name }).sorted()
        allExerciseNames = names
        if selectedExercise != "All" && !names.contains(selectedExercise) {
            selectedExercise = "All"
        }
        loading = false
    }
}
