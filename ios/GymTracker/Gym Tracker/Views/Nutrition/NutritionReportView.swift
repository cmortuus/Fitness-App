import SwiftUI
import Charts

/// Nutrition report page with trends and adherence (#478)
struct NutritionReportView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var period = 30
    @State private var trends: TrendsResponse? = nil
    @State private var adherence: AdherenceResponse? = nil
    @State private var loading = true

    struct TrendsResponse: Decodable {
        let period: Int
        let days_logged: Int
        let daily: [DailyPoint]
        let rolling_7_day: MacroAvg
        let rolling_14_day: MacroAvg
    }

    struct DailyPoint: Decodable, Identifiable {
        var id: String { date }
        let date: String
        let calories: Int
        let protein: Int
        let carbs: Int
        let fat: Int
    }

    struct MacroAvg: Decodable {
        let calories: Int
        let protein: Int
        let carbs: Int
        let fat: Int
    }

    struct AdherenceResponse: Decodable {
        let period: Int
        let days_logged: Int
        let days_total: Int
        let logging_pct: Int
        let current_streak: Int
        let best_streak: Int
        let calorie_target: Int?
        let calorie_adherence_pct: Int?
        let protein_adherence_pct: Int?
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Period picker
                Picker("Period", selection: $period) {
                    Text("7d").tag(7)
                    Text("14d").tag(14)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: period) { _, _ in Task { await loadData() } }

                if loading {
                    ProgressView().padding(.top, 40)
                } else {
                    // Adherence card
                    if let adh = adherence {
                        adherenceCard(adh)
                    }

                    // Rolling averages
                    if let t = trends {
                        rollingAveragesCard(t)
                    }

                    // Calorie trend chart
                    if let t = trends, !t.daily.isEmpty {
                        calorieTrendChart(t.daily)
                    }

                    // Protein trend chart
                    if let t = trends, !t.daily.isEmpty {
                        proteinTrendChart(t.daily)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 80)
        }
        .background(AppColors.zinc950)
        .navigationTitle("Nutrition Report")
        .task { await loadData() }
    }

    private func adherenceCard(_ adh: AdherenceResponse) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                statPill("Logged", "\(adh.days_logged)/\(adh.days_total)", .blue)
                statPill("Streak", "\(adh.current_streak)d", .green)
                statPill("Best", "\(adh.best_streak)d", .yellow)
            }
            if let cal = adh.calorie_adherence_pct {
                HStack {
                    Text("Calorie adherence").font(.caption).foregroundStyle(AppColors.zinc500)
                    Spacer()
                    Text("\(cal)%").font(.subheadline.bold()).foregroundStyle(cal >= 80 ? .green : .orange)
                }
            }
            if let pro = adh.protein_adherence_pct {
                HStack {
                    Text("Protein adherence").font(.caption).foregroundStyle(AppColors.zinc500)
                    Spacer()
                    Text("\(pro)%").font(.subheadline.bold()).foregroundStyle(pro >= 80 ? .green : .orange)
                }
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
        .padding(.horizontal)
    }

    private func statPill(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(AppColors.zinc500)
        }
        .frame(maxWidth: .infinity)
    }

    private func rollingAveragesCard(_ t: TrendsResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rolling Averages").font(.subheadline.bold())
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text("7-day").font(.caption2).foregroundStyle(AppColors.zinc500)
                    Text("\(t.rolling_7_day.calories)").font(.subheadline.bold()).foregroundStyle(.orange)
                    Text("kcal").font(.caption2).foregroundStyle(AppColors.zinc500)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text("14-day").font(.caption2).foregroundStyle(AppColors.zinc500)
                    Text("\(t.rolling_14_day.calories)").font(.subheadline.bold()).foregroundStyle(.orange)
                    Text("kcal").font(.caption2).foregroundStyle(AppColors.zinc500)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 2) {
                    Text("P avg").font(.caption2).foregroundStyle(AppColors.zinc500)
                    Text("\(t.rolling_7_day.protein)g").font(.subheadline.bold()).foregroundStyle(.blue)
                    Text("protein").font(.caption2).foregroundStyle(AppColors.zinc500)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
        .padding(.horizontal)
    }

    private func calorieTrendChart(_ daily: [DailyPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calories").font(.subheadline.bold())
            Chart(daily) { day in
                BarMark(x: .value("Date", day.date), y: .value("Cal", day.calories))
                    .foregroundStyle(.orange.gradient)
            }
            .frame(height: 150)
            .chartXAxis(.hidden)
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
        .padding(.horizontal)
    }

    private func proteinTrendChart(_ daily: [DailyPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Protein").font(.subheadline.bold())
            Chart(daily) { day in
                BarMark(x: .value("Date", day.date), y: .value("Protein", day.protein))
                    .foregroundStyle(.blue.gradient)
            }
            .frame(height: 150)
            .chartXAxis(.hidden)
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
        .padding(.horizontal)
    }

    private func loadData() async {
        loading = true
        let q = [URLQueryItem(name: "period", value: "\(period)")]
        trends = try? await APIClient.shared.get("/nutrition/trends", query: q)
        adherence = try? await APIClient.shared.get("/nutrition/adherence", query: q)
        loading = false
    }
}
