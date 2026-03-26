import SwiftUI

struct WorkoutSummaryView: View {
    let workoutName: String
    let duration: Int // seconds
    let exercises: [UIExercise]
    let prs: [PR]
    let onDismiss: () -> Void

    @State private var sessionNotes = ""

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
                ], spacing: 16) {
                    StatBox(label: "Sets", value: "\(totalSets)")
                    StatBox(label: "Duration", value: formatDuration(duration))
                    StatBox(label: "Volume", value: formatVolume(totalVolume))
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
                    ForEach(exercises) { ex in
                        HStack {
                            Text(ex.name)
                                .font(.subheadline)
                            Spacer()
                            let done = ex.sets.filter(\.done).count
                            Text("\(done)/\(ex.sets.count) sets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                // Share + Home buttons
                HStack(spacing: 16) {
                    ShareLink(item: summaryText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onDismiss) {
                        Label("Home", systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationBarBackButtonHidden()
    }

    private var summaryText: String {
        """
        💪 \(workoutName)
        ⏱ \(formatDuration(duration))
        📊 \(totalSets) sets · \(totalReps) reps · \(formatVolume(totalVolume))
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
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        return "\(Int(v))"
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
