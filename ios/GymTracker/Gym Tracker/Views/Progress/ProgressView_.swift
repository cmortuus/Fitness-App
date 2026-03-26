import SwiftUI
import Charts

struct ProgressView_: View {
    @State private var records: [PersonalRecord] = []
    @State private var insights: [ProgressInsight] = []
    @State private var bodyWeights: [BodyWeightEntry] = []
    @State private var loading = true
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("1RM").tag(0)
                    Text("Records").tag(1)
                    Text("Weight").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    if loading {
                        ProgressView().padding(.top, 40)
                    } else {
                        switch selectedTab {
                        case 0: oneRMChart
                        case 1: recordsList
                        case 2: bodyWeightChart
                        default: EmptyView()
                        }
                    }
                }
            }
            .navigationTitle("Progress")
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    private var oneRMChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            if insights.isEmpty {
                emptyState("Complete some workouts to see 1RM trends")
            } else {
                Chart(insights.filter { $0.estimated_1rm != nil }, id: \.exercise_id) { insight in
                    BarMark(
                        x: .value("1RM", insight.estimated_1rm ?? 0),
                        y: .value("Exercise", insight.exercise_name)
                    )
                    .foregroundStyle(trendColor(insight.trend))
                }
                .chartXAxisLabel("Estimated 1RM (lbs)")
                .frame(height: CGFloat(max(insights.count * 40, 200)))
                .padding()
            }
        }
    }

    private var recordsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if records.isEmpty {
                emptyState("No records yet — complete some workouts!")
            } else {
                ForEach(records, id: \.exercise_id) { record in
                    HStack {
                        Text(record.exercise_name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let rm = record.best_1rm {
                            Text("\(Int(rm * 2.20462)) lbs")
                                .font(.subheadline.bold())
                                .foregroundStyle(.blue)
                                .frame(width: 80)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical)
    }

    private var bodyWeightChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bodyWeights.isEmpty {
                emptyState("Log body weight in Settings to see trends")
            } else {
                Chart(bodyWeights.reversed()) { entry in
                    LineMark(
                        x: .value("Date", String(entry.recorded_at?.prefix(10) ?? "")),
                        y: .value("Weight", entry.weight_kg * 2.20462)
                    )
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("Date", String(entry.recorded_at?.prefix(10) ?? "")),
                        y: .value("Weight", entry.weight_kg * 2.20462)
                    )
                    .foregroundStyle(.blue)
                }
                .chartYAxisLabel("lbs")
                .frame(height: 250)
                .padding()
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 40).frame(maxWidth: .infinity)
    }

    private func trendColor(_ trend: String?) -> Color {
        switch trend { case "up": return .green; case "down": return .red; default: return .blue }
    }

    private func loadData() async {
        do {
            async let i: [ProgressInsight] = APIClient.shared.get("/progress/insights")
            async let r: [PersonalRecord] = APIClient.shared.get("/progress/records")
            async let bw: [BodyWeightEntry] = APIClient.shared.get("/body-weight/", query: [.init(name: "limit", value: "90")])
            insights = try await i; records = try await r; bodyWeights = try await bw
        } catch { print("[Progress] Load: \(error)") }
        loading = false
    }
}
