import SwiftUI
import Charts

/// Read-only activity tab — shows workouts from the PWA + body weight trend
struct ActivityView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var sessions: [WorkoutSession] = []
    @State private var bodyWeights: [BodyWeightEntry] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(.top, 60)
                } else {
                    VStack(spacing: 16) {
                        // Body weight chart
                        bodyWeightCard

                        // Recent workouts
                        workoutsCard

                        // Sync info
                        syncInfoCard
                    }
                    .padding()
                    .padding(.bottom, 60)
                }
            }
            .background(AppColors.zinc950)
            .navigationTitle("Activity")
            .task { await loadData() }
            .refreshable { await loadData() }
        }
    }

    // MARK: - Body Weight Card

    private var bodyWeightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Body Weight").font(.headline)
                Spacer()
                if let latest = bodyWeights.first {
                    let w = weightUnit == "lbs" ? latest.weight_kg * 2.20462 : latest.weight_kg
                    Text(String(format: "%.1f %@", w, weightUnit))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(AppColors.primary)
                }
            }

            if bodyWeights.count >= 2 {
                Chart(bodyWeights.suffix(30).reversed(), id: \.id) { entry in
                    let w = weightUnit == "lbs" ? entry.weight_kg * 2.20462 : entry.weight_kg
                    LineMark(
                        x: .value("Date", entry.recorded_at),
                        y: .value("Weight", w)
                    )
                    .foregroundStyle(AppColors.primary.gradient)
                    .interpolationMethod(.catmullRom)
                }
                .frame(height: 120)
                .chartYScale(domain: .automatic(includesZero: false))
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    // MARK: - Workouts Card

    private var workoutsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Workouts").font(.headline)
                Spacer()
                Text("\(sessions.count)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(AppColors.zinc500)
            }

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell").font(.title2).foregroundStyle(AppColors.zinc600)
                    Text("No workouts yet").font(.subheadline).foregroundStyle(AppColors.zinc500)
                    Text("Log workouts in the web app").font(.caption).foregroundStyle(AppColors.zinc600)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(sessions.prefix(10)) { session in
                    sessionRow(session)
                    if session.id != sessions.prefix(10).last?.id {
                        Divider().background(AppColors.zinc800)
                    }
                }
            }
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? "Workout")
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let sets = session.total_sets {
                        Text("\(sets) sets").font(.caption2).foregroundStyle(AppColors.zinc500)
                    }
                    if let vol = session.total_volume_kg {
                        let v = weightUnit == "lbs" ? vol * 2.20462 : vol
                        Text(v >= 1000 ? String(format: "%.1fk %@", v/1000, weightUnit) : "\(Int(v)) \(weightUnit)")
                            .font(.caption2).foregroundStyle(AppColors.zinc500)
                    }
                }
            }
            Spacer()
            Text(session.date ?? "")
                .font(.caption)
                .foregroundStyle(AppColors.zinc600)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sync Info

    private var syncInfoCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(AppColors.primary)
            Text("Workouts sync to Apple Health automatically")
                .font(.caption).foregroundStyle(AppColors.zinc500)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            sessions = try await APIClient.shared.get("/sessions/",
                query: [.init(name: "limit", value: "30")])
            sessions = sessions.filter { $0.status == "completed" }
        } catch { print("[Activity] Sessions: \(error)") }

        do {
            bodyWeights = try await APIClient.shared.get("/body-weight/",
                query: [.init(name: "limit", value: "30")])
        } catch { print("[Activity] BodyWeight: \(error)") }

        loading = false
    }
}
