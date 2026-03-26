import SwiftUI
import Charts

struct ProgressView_: View {
    @State private var records: [PersonalRecord] = []
    @State private var insights: [ProgressInsight] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if loading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        // 1RM chart
                        if !insights.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Estimated 1RM Trends")
                                    .font(.headline)

                                Chart(insights, id: \.exercise_id) { insight in
                                    if let current = insight.estimated_1rm {
                                        BarMark(
                                            x: .value("Exercise", insight.exercise_name),
                                            y: .value("1RM", current)
                                        )
                                        .foregroundStyle(trendColor(insight.trend))
                                    }
                                }
                                .frame(height: 200)
                                .chartXAxis {
                                    AxisMarks { _ in
                                        AxisValueLabel()
                                            .font(.caption2)
                                    }
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        // Personal records
                        if !records.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Personal Records")
                                    .font(.headline)

                                ForEach(records, id: \.exercise_id) { record in
                                    HStack {
                                        Text(record.exercise_name)
                                            .font(.subheadline)
                                        Spacer()
                                        if let rm = record.best_1rm {
                                            Text("\(Int(rm)) kg")
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        if insights.isEmpty && records.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text("Complete some workouts to see progress!")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 40)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Progress")
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    private func loadData() async {
        do {
            async let i: [ProgressInsight] = APIClient.shared.get("/progress/insights")
            async let r: [PersonalRecord] = APIClient.shared.get("/progress/records")
            insights = try await i
            records = try await r
            loading = false
        } catch {
            print("Progress load error: \(error)")
            loading = false
        }
    }

    private func trendColor(_ trend: String?) -> Color {
        switch trend {
        case "up": return .green
        case "down": return .red
        default: return .blue
        }
    }
}
