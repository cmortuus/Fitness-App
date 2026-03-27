import SwiftUI

/// Shows the last 8 sessions for a given exercise
struct ExerciseHistoryView: View {
    let exerciseId: Int
    let exerciseName: String

    @State private var history: [SessionHistory] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading history...")
                        .padding(.top, 40)
                } else if history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No history yet")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(history) { session in
                                sessionCard(session)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(exerciseName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadHistory() }
        }
    }

    private func sessionCard(_ session: SessionHistory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.sessionName)
                    .font(.caption.bold())
                Spacer()
                Text(session.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let week = session.week {
                Text("Week \(week)")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            // Set rows
            ForEach(session.sets.indices, id: \.self) { i in
                let set = session.sets[i]
                HStack(spacing: 12) {
                    Text("Set \(i + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    if let w = set.weight {
                        Text("\(Int(w)) lbs")
                            .font(.caption.bold())
                    }

                    if let r = set.reps {
                        Text("× \(r)")
                            .font(.caption)
                    }

                    if let type = set.setType, type != "standard" {
                        Text(type)
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }

                    Spacer()

                    if set.completed {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func loadHistory() async {
        do {
            let sessions: [WorkoutSession] = try await APIClient.shared.get(
                "/sessions/",
                query: [.init(name: "limit", value: "50")]
            )

            let kgToLbs = 2.20462

            // Filter sessions that contain this exercise and are completed
            var results: [SessionHistory] = []
            for session in sessions where session.status == "completed" {
                // Fetch full session with sets
                let full: WorkoutSession = try await APIClient.shared.get("/sessions/\(session.id)")
                let matchingSets = (full.sets ?? []).filter { ($0.exercise_id ?? 0) == exerciseId }
                if !matchingSets.isEmpty {
                    results.append(SessionHistory(
                        id: session.id,
                        sessionName: session.name ?? "Workout",
                        date: String((session.date ?? "").prefix(10)),
                        week: nil,
                        sets: matchingSets.map { s in
                            HistorySet(
                                weight: s.actual_weight_kg != nil ? (s.actual_weight_kg! * kgToLbs / 5).rounded() * 5 : nil,
                                reps: s.actual_reps,
                                setType: s.set_type,
                                completed: s.completed_at != nil
                            )
                        }
                    ))
                }
                if results.count >= 8 { break }
            }

            history = results
        } catch {
            print("[History] Load error: \(error)")
        }
        loading = false
    }
}

// MARK: - History Models

struct SessionHistory: Identifiable {
    let id: Int
    let sessionName: String
    let date: String
    let week: Int?
    let sets: [HistorySet]
}

struct HistorySet {
    let weight: Double?
    let reps: Int?
    let setType: String?
    let completed: Bool
}
