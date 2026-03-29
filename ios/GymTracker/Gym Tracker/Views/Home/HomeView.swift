import SwiftUI
import Charts

/// MacroFactor-style home dashboard — numbers-first nutrition overview
struct HomeView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var summary: DailySummary?
    @State private var waterSummary: WaterSummary?
    @State private var activePhase: DietPhase?
    @State private var bodyWeights: [BodyWeightEntry] = []
    @State private var loading = true

    private let accentBlue = Color(red: 0.004, green: 0.439, blue: 0.725) // #0170B9

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(.top, 60)
                } else {
                    VStack(spacing: 20) {
                        // Calories remaining hero
                        caloriesCard

                        // Macro numbers row
                        macroNumbersCard

                        // Weight trend
                        if !bodyWeights.isEmpty {
                            weightTrendCard
                        }

                        // Phase status
                        phaseCard

                        // Water
                        waterCard

                        // Quick links
                        quickLinksRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 80)
                }
            }
            .background(Color.black)
            .navigationTitle(todayFormatted)
            .navigationBarTitleDisplayMode(.large)
            .task { await loadAll() }
            .refreshable { await loadAll() }
        }
    }

    private var todayFormatted: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMM d"
        return df.string(from: Date())
    }

    // MARK: - Calories Card

    private var caloriesCard: some View {
        let totals = summary?.totals ?? MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)
        let goalCal = summary?.goals?.calories ?? 0
        let remaining = goalCal - totals.calories

        return VStack(spacing: 8) {
            if goalCal > 0 {
                Text("Remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1)

                Text("\(Int(remaining))")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remaining >= 0 ? .white : .red)

                Text("kcal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                        Capsule().fill(totals.calories > goalCal ? .red : accentBlue)
                            .frame(width: geo.size.width * min(goalCal > 0 ? totals.calories / goalCal : 0, 1.0), height: 6)
                    }
                }
                .frame(height: 6)
                .padding(.top, 4)

                HStack {
                    Text("\(Int(totals.calories)) eaten")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(goalCal)) target")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("\(Int(totals.calories))")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("calories today")
                    .font(.subheadline).foregroundStyle(.secondary)

                NavigationLink("Set Goals") {
                    // TODO: goals sheet
                }
                .font(.caption.bold())
                .foregroundStyle(accentBlue)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Macro Numbers

    private var macroNumbersCard: some View {
        let totals = summary?.totals ?? MacroTotals(calories: 0, protein: 0, carbs: 0, fat: 0)
        let goals = summary?.goals

        return HStack(spacing: 0) {
            macroNumber("Protein", value: totals.protein, goal: goals?.protein, unit: "g", color: accentBlue)
            Divider().frame(height: 40).background(Color.white.opacity(0.1))
            macroNumber("Carbs", value: totals.carbs, goal: goals?.carbs, unit: "g", color: .white)
            Divider().frame(height: 40).background(Color.white.opacity(0.1))
            macroNumber("Fat", value: totals.fat, goal: goals?.fat, unit: "g", color: .white)
        }
        .padding(.vertical, 16)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func macroNumber(_ label: String, value: Double, goal: Double?, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            HStack(spacing: 2) {
                Text("\(Int(value))")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(color)
                if let g = goal {
                    Text("/ \(Int(g))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Weight Trend

    private var weightTrendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weight")
                    .font(.subheadline.bold())
                Spacer()
                if let latest = bodyWeights.first {
                    let w = weightUnit == "lbs" ? latest.weight_kg * 2.20462 : latest.weight_kg
                    Text(String(format: "%.1f %@", w, weightUnit))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(accentBlue)
                }
            }

            Chart(bodyWeights.suffix(14).reversed(), id: \.id) { entry in
                let w = weightUnit == "lbs" ? entry.weight_kg * 2.20462 : entry.weight_kg
                LineMark(
                    x: .value("Date", entry.recorded_at ?? ""),
                    y: .value("Weight", w)
                )
                .foregroundStyle(accentBlue.gradient)
                .interpolationMethod(.catmullRom)
            }
            .frame(height: 80)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
        .padding(20)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Phase Card

    @ViewBuilder
    private var phaseCard: some View {
        if let phase = activePhase {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(phase.phase_type.capitalized)
                        .font(.subheadline.bold())
                    Text("Week \(phase.current_week ?? 1) of \(phase.duration_weeks ?? 12)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let progress = Double(phase.current_week ?? 1) / Double(phase.duration_weeks ?? 12)
                CircularProgressView(progress: progress, color: accentBlue)
                    .frame(width: 36, height: 36)
            }
            .padding(16)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Water Card

    @ViewBuilder
    private var waterCard: some View {
        if let water = waterSummary {
            HStack {
                Image(systemName: "drop.fill")
                    .foregroundStyle(accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Water")
                        .font(.subheadline.bold())
                    Text("\(Int(water.total_ml)) / \(Int(water.goal_ml)) ml")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                        Capsule().fill(accentBlue)
                            .frame(width: geo.size.width * min(water.total_ml / max(water.goal_ml, 1), 1.0), height: 6)
                    }
                }
                .frame(width: 100, height: 6)
            }
            .padding(16)
            .background(Color(white: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Quick Links

    private var quickLinksRow: some View {
        HStack(spacing: 12) {
            NavigationLink {
                NutritionReportView()
            } label: {
                quickLink(icon: "chart.bar.fill", label: "Reports")
            }
            NavigationLink {
                RecipesView(date: dateString, onLog: { Task { await loadAll() } })
            } label: {
                quickLink(icon: "book.fill", label: "Recipes")
            }
        }
    }

    private func quickLink(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accentBlue)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Data Loading

    private func loadAll() async {
        do {
            summary = try await APIClient.shared.get("/nutrition/summary",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Home] Summary: \(error)") }
        do {
            waterSummary = try await APIClient.shared.get("/nutrition/water",
                query: [.init(name: "date", value: dateString)])
        } catch { print("[Home] Water: \(error)") }
        do {
            bodyWeights = try await APIClient.shared.get("/body-weight/",
                query: [.init(name: "limit", value: "14")])
        } catch { print("[Home] BodyWeight: \(error)") }
        activePhase = try? await APIClient.shared.get("/nutrition/phases/active")
        loading = false
    }
}

// MARK: - Circular Progress

struct CircularProgressView: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
