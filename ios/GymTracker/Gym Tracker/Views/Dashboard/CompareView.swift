import SwiftUI

/// Side-by-side session comparison (#472)
struct CompareView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @State private var sessions: [WorkoutSession] = []
    @State private var sessionA: WorkoutSession? = nil
    @State private var sessionB: WorkoutSession? = nil
    @State private var detailA: SessionDetail? = nil
    @State private var detailB: SessionDetail? = nil
    @State private var loading = true

    struct SessionDetail: Decodable {
        let id: Int
        let name: String?
        let exercises: [SessionExercise]?
    }

    struct SessionExercise: Decodable, Identifiable {
        let id: Int
        let exercise_id: Int
        let exercise_name: String
        let sets: [SessionSet]?
    }

    struct SessionSet: Decodable {
        let actual_weight_kg: Double?
        let actual_reps: Int?
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Session pickers
                HStack(spacing: 12) {
                    sessionPicker("Older", selection: $sessionA)
                    sessionPicker("Newer", selection: $sessionB)
                }

                if let a = detailA, let b = detailB {
                    // Overview
                    overviewCard(a: a, b: b)

                    // Per-exercise comparison
                    ForEach(exerciseComparison(a: a, b: b), id: \.name) { comp in
                        exerciseComparisonRow(comp)
                    }
                } else if sessionA != nil && sessionB != nil {
                    ProgressView("Loading sessions...").padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("Select two sessions to compare")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .background(AppColors.zinc950)
        .navigationTitle("Compare")
        .task {
            do {
                sessions = try await APIClient.shared.get("/sessions/",
                    query: [.init(name: "limit", value: "30")])
                sessions = sessions.filter { $0.status == "completed" }
            } catch { print("[Compare] Load: \(error)") }
            loading = false
        }
        .onChange(of: sessionA?.id) { _, _ in Task { await loadDetails() } }
        .onChange(of: sessionB?.id) { _, _ in Task { await loadDetails() } }
    }

    private func sessionPicker(_ label: String, selection: Binding<WorkoutSession?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(AppColors.zinc500)
            Menu {
                ForEach(sessions) { session in
                    Button(session.name ?? "Workout") {
                        selection.wrappedValue = session
                    }
                }
            } label: {
                Text(selection.wrappedValue?.name ?? "Select...")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppColors.zinc900)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppColors.zinc800, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func overviewCard(a: SessionDetail, b: SessionDetail) -> some View {
        let aExCount = a.exercises?.count ?? 0
        let bExCount = b.exercises?.count ?? 0
        let aSets = a.exercises?.flatMap { $0.sets ?? [] }.count ?? 0
        let bSets = b.exercises?.flatMap { $0.sets ?? [] }.count ?? 0

        return HStack(spacing: 0) {
            overviewStat("Exercises", a: "\(aExCount)", b: "\(bExCount)")
            overviewStat("Sets", a: "\(aSets)", b: "\(bSets)")
        }
        .padding()
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    private func overviewStat(_ label: String, a: String, b: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(AppColors.zinc500)
            HStack(spacing: 8) {
                Text(a).font(.subheadline.monospacedDigit()).foregroundStyle(AppColors.zinc400)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(AppColors.zinc600)
                Text(b).font(.subheadline.bold().monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity)
    }

    struct ExerciseComparison {
        let name: String
        let aWeight: Double?
        let aReps: Int?
        let bWeight: Double?
        let bReps: Int?
    }

    private func exerciseComparison(a: SessionDetail, b: SessionDetail) -> [ExerciseComparison] {
        let allNames = Set((a.exercises ?? []).map(\.exercise_name) + (b.exercises ?? []).map(\.exercise_name))
        return allNames.sorted().map { name in
            let aEx = a.exercises?.first { $0.exercise_name == name }
            let bEx = b.exercises?.first { $0.exercise_name == name }
            let aBest = aEx?.sets?.compactMap(\.actual_weight_kg).max()
            let bBest = bEx?.sets?.compactMap(\.actual_weight_kg).max()
            let aReps = aEx?.sets?.compactMap(\.actual_reps).max()
            let bReps = bEx?.sets?.compactMap(\.actual_reps).max()
            return ExerciseComparison(name: name, aWeight: aBest, aReps: aReps, bWeight: bBest, bReps: bReps)
        }
    }

    private func exerciseComparisonRow(_ comp: ExerciseComparison) -> some View {
        let kgToLbs = 2.20462
        let aW = comp.aWeight.map { weightUnit == "lbs" ? $0 * kgToLbs : $0 }
        let bW = comp.bWeight.map { weightUnit == "lbs" ? $0 * kgToLbs : $0 }
        let delta = (aW != nil && bW != nil) ? bW! - aW! : nil
        let deltaColor: Color = delta == nil ? .secondary : (delta! > 0 ? .green : delta! < 0 ? .red : .secondary)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(comp.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    if let w = aW { Text("\(Int(w))\(weightUnit)").font(.caption2).foregroundStyle(AppColors.zinc500) }
                    else { Text("—").font(.caption2).foregroundStyle(AppColors.zinc500) }
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(AppColors.zinc600)
                    if let w = bW { Text("\(Int(w))\(weightUnit)").font(.caption2.bold()) }
                    else { Text("—").font(.caption2) }
                }
            }
            Spacer()
            if let d = delta {
                Text(d >= 0 ? "+\(Int(d))" : "\(Int(d))")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(deltaColor)
            }
        }
        .padding(12)
        .background(AppColors.zinc900)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColors.zinc800, lineWidth: 1))
    }

    private func loadDetails() async {
        guard let a = sessionA, let b = sessionB else { return }
        do {
            detailA = try await APIClient.shared.get("/sessions/\(a.id)")
            detailB = try await APIClient.shared.get("/sessions/\(b.id)")
        } catch { print("[Compare] Detail: \(error)") }
    }
}
