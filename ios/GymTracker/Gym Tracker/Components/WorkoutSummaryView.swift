import SwiftUI

struct WorkoutSummaryView: View {
    let workoutName: String
    let duration: Int // seconds
    let exercises: [UIExercise]
    let prs: [PR]
    let sessionId: Int?
    let planId: Int?
    let onDismiss: () -> Void

    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"
    @AppStorage(SettingsKey.lastBodyWeightKg) private var bodyWeightKg: Double = 70

    @State private var sessionNotes = ""
    @State private var updatePlan = true
    @State private var syncingPlan = false
    @State private var syncDone = false
    @State private var syncCount = 0

    private var totalSets: Int {
        exercises.flatMap(\.sets).filter(\.done).count
    }

    private var totalReps: Int {
        exercises.flatMap(\.sets).filter(\.done).compactMap(\.reps).reduce(0, +)
    }

    private var totalVolume: Double {
        exercises.flatMap(\.sets).filter(\.done).reduce(0.0) { sum, set in
            sum + (set.weight ?? 0) * Double(set.reps ?? 0)
        }
    }

    /// Calorie estimate using per-exercise MET values from Compendium of Physical Activities.
    private var estimatedCalories: Int {
        let kcal = HealthKitManager.shared.estimateCalories(
            exercises: exercises,
            durationSeconds: TimeInterval(duration),
            bodyWeightKg: bodyWeightKg
        )
        return max(1, Int(kcal.rounded()))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Celebration
                Text("🎉")
                    .font(.system(size: 60))
                Text("Workout Complete!")
                    .font(.title.bold())
                Text(workoutName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 12) {
                    StatBox(label: "Sets", value: "\(totalSets)")
                    StatBox(label: "Duration", value: formatDuration(duration))
                    StatBox(label: "Volume", value: formatVolume(totalVolume))
                    StatBox(label: "~kcal", value: "\(estimatedCalories)")
                }

                // PRs
                if !prs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🏆 Personal Records")
                            .font(.headline)
                        ForEach(prs.indices, id: \.self) { i in
                            HStack {
                                Text(prs[i].exerciseName)
                                    .font(.subheadline)
                                Spacer()
                                Text(prs[i].value)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Exercise breakdown
                VStack(alignment: .leading, spacing: 8) {
                    Text("Exercise Summary")
                        .font(.headline)
                    ForEach(exercises.indices, id: \.self) { i in
                        let ex = exercises[i]
                        let doneSets = ex.sets.filter(\.done)
                        let exVolume = doneSets.reduce(0.0) { $0 + ($1.weight ?? 0) * Double($1.reps ?? 0) }
                        let dispVolume = weightUnit == "lbs" ? exVolume * 2.20462 : exVolume

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(ex.name)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text("\(doneSets.count)/\(ex.sets.count) sets")
                                    .font(.caption)
                                    .foregroundStyle(doneSets.count == ex.sets.count ? .green : .secondary)
                            }
                            if !doneSets.isEmpty {
                                let weightValues = doneSets.compactMap(\.weight)
                                let repValues = doneSets.compactMap(\.reps)
                                if !weightValues.isEmpty, !repValues.isEmpty {
                                    HStack(spacing: 8) {
                                        Text(formatSetSummary(doneSets))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if dispVolume > 0 {
                                            Text("·")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                            Text("\(Int(dispVolume)) \(weightUnit)")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                            }
                        }
                        if i < exercises.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Notes")
                        .font(.headline)
                    TextField("How did the workout feel?", text: $sessionNotes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Update plan toggle (only shown when session is linked to a plan)
                if planId != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $updatePlan) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Update plan with today's weights")
                                    .font(.subheadline.bold())
                                Text("Saves your actual weights & reps back to the plan template.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if syncDone {
                            Label("\(syncCount) exercise\(syncCount == 1 ? "" : "s") updated", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Share + Home buttons
                HStack(spacing: 16) {
                    ShareLink(item: summaryText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await syncAndDismiss() }
                    } label: {
                        if syncingPlan {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Home", systemImage: "house.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationBarBackButtonHidden()
    }

    // MARK: - Actions

    private func syncAndDismiss() async {
        guard let sid = sessionId else { onDismiss(); return }
        syncingPlan = true

        // Save notes if non-empty
        let trimmedNotes = sessionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            struct NotesBody: Encodable { let notes: String }
            do {
                let _: WorkoutSession = try await APIClient.shared.patch(
                    "/sessions/\(sid)",
                    body: NotesBody(notes: trimmedNotes)
                )
            } catch {
                print("[Summary] Notes save error: \(error)")
            }
        }

        // Sync to plan if enabled
        if updatePlan, planId != nil, !syncDone {
            do {
                struct SyncResponse: Decodable { let updated: Int }
                let resp: SyncResponse = try await APIClient.shared.post(
                    "/sessions/\(sid)/sync-to-plan"
                )
                await MainActor.run {
                    syncCount = resp.updated
                    syncDone = true
                }
            } catch {
                print("[Summary] Sync-to-plan error: \(error)")
            }
        }

        syncingPlan = false
        onDismiss()
    }

    private var summaryText: String {
        """
        💪 \(workoutName)
        ⏱ \(formatDuration(duration))
        📊 \(totalSets) sets · \(totalReps) reps · \(formatVolume(totalVolume)) \(weightUnit)
        🔥 ~\(estimatedCalories) kcal
        \(prs.isEmpty ? "" : "🏆 \(prs.count) PR\(prs.count > 1 ? "s" : "")!")
        """
    }

    private func formatDuration(_ secs: Int) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatVolume(_ v: Double) -> String {
        // v is in display units already (lbs or kg depending on how sets are stored)
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        return "\(Int(v))"
    }

    /// Summarize sets as "4 × 185" or "3 × 185, 1 × 175" for the top weights
    private func formatSetSummary(_ sets: [UISet]) -> String {
        // Group by weight
        var groups: [(weight: Double, count: Int)] = []
        for set in sets {
            let w = set.weight ?? 0
            if let idx = groups.firstIndex(where: { abs($0.weight - w) < 0.1 }) {
                groups[idx].count += 1
            } else {
                groups.append((weight: w, count: 1))
            }
        }
        let kgToLbs = 2.20462
        let parts = groups.prefix(2).map { g -> String in
            let disp = weightUnit == "lbs" ? g.weight * kgToLbs : g.weight
            let wStr = disp == disp.rounded() ? "\(Int(disp))" : String(format: "%.1f", disp)
            return "\(g.count) × \(wStr)"
        }
        let suffix = groups.count > 2 ? " …" : ""
        return parts.joined(separator: ", ") + suffix
    }
}

struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
