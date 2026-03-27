import SwiftUI

struct WorkoutHistoryView: View {
    @AppStorage(SettingsKey.weightUnit) private var weightUnit: String = "lbs"

    @State private var sessions: [WorkoutSession] = []
    @State private var loading = true
    @State private var loadingMore = false
    @State private var hasMore = true
    private let pageSize = 20

    var body: some View {
        Group {
            if loading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Workouts Yet")
                        .font(.title2.bold())
                    Text("Complete a workout to see your history here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyList
            }
        }
        .navigationTitle("Workout History")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadSessions(reset: true) }
        .refreshable { await loadSessions(reset: true) }
    }

    // MARK: - List

    private var historyList: some View {
        List {
            ForEach(groupedByMonth, id: \.0) { month, monthSessions in
                Section(header: Text(month).font(.subheadline.bold()).foregroundStyle(.secondary)) {
                    ForEach(monthSessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session, weightUnit: weightUnit)
                        } label: {
                            sessionRow(session)
                        }
                    }
                }
            }

            if hasMore {
                HStack {
                    Spacer()
                    if loadingMore {
                        ProgressView()
                    } else {
                        Button("Load More") {
                            Task { await loadSessions(reset: false) }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Session Row

    private func sessionRow(_ session: WorkoutSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Date circle
            let dayStr = session.date.flatMap { String($0.prefix(10)) } ?? ""
            let dayNum = dayStr.components(separatedBy: "-").last ?? "?"

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Text(dayNum)
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? "Workout")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let sets = session.total_sets {
                        Label("\(sets) sets", systemImage: "list.number")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let vol = session.total_volume_kg, vol > 0 {
                        let disp = weightUnit == "lbs" ? vol * 2.20462 : vol
                        Label("\(Int(disp)) \(weightUnit)", systemImage: "scalemass")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            // Duration
            if let started = session.started_at, let completed = session.completed_at {
                let mins = durationMinutes(from: started, to: completed)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatMins(mins))
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Text("min")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Grouping by Month

    private var groupedByMonth: [(String, [WorkoutSession])] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM yyyy"

        var grouped: [String: [WorkoutSession]] = [:]
        var order: [String] = []

        for session in sessions {
            let dateStr = session.date.flatMap { String($0.prefix(10)) } ?? ""
            let monthKey: String
            if let date = df.date(from: dateStr) {
                monthKey = monthFmt.string(from: date)
            } else {
                monthKey = "Unknown"
            }
            if grouped[monthKey] == nil {
                order.append(monthKey)
                grouped[monthKey] = []
            }
            grouped[monthKey]!.append(session)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    // MARK: - Data Loading

    private func loadSessions(reset: Bool) async {
        if reset {
            loading = true
            sessions = []
        } else {
            loadingMore = true
        }

        do {
            let offset = reset ? 0 : sessions.count
            let newSessions: [WorkoutSession] = try await APIClient.shared.get("/sessions/",
                query: [
                    .init(name: "limit", value: "\(pageSize)"),
                    .init(name: "offset", value: "\(offset)"),
                    .init(name: "status", value: "completed"),
                ])
            if reset {
                sessions = newSessions
            } else {
                sessions.append(contentsOf: newSessions)
            }
            hasMore = newSessions.count == pageSize
        } catch {
            print("[WorkoutHistory] Load error: \(error)")
        }
        loading = false
        loadingMore = false
    }

    // MARK: - Helpers

    private func durationMinutes(from: String, to: String) -> Int {
        let df = ISO8601DateFormatter()
        guard let start = df.date(from: from), let end = df.date(from: to) else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }

    private func formatMins(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)" }
        return "\(mins / 60)h \(mins % 60)"
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: WorkoutSession
    let weightUnit: String

    @State private var detail: WorkoutSession? = nil
    @State private var loading = true

    private var displayWeight: (Double) -> Double {
        { weightUnit == "lbs" ? $0 * 2.20462 : $0 }
    }

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding(.top, 40)
            } else if let s = detail ?? session as WorkoutSession?,
                      let sets = s.sets, !sets.isEmpty {
                sessionDetailContent(s, sets: sets)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "dumbbell").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No set data recorded").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .navigationTitle(session.name ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
    }

    private func sessionDetailContent(_ s: WorkoutSession, sets: [ExerciseSet]) -> some View {
        VStack(spacing: 16) {
            // Session notes (if any)
            if let notes = s.notes, !notes.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            // Summary stats
            let completed = sets.filter { $0.completed_at != nil }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statBox(label: "Sets", value: "\(completed.count)")
                statBox(label: "Volume", value: {
                    let vol = completed.reduce(0.0) { $0 + (($1.actual_weight_kg ?? 0) * Double($1.actual_reps ?? 0)) }
                    let disp = displayWeight(vol)
                    return disp >= 1000 ? String(format: "%.1fk", disp / 1000) : "\(Int(disp))"
                }())
                if let start = s.started_at, let end = s.completed_at {
                    let mins = durationMinutes(from: start, to: end)
                    statBox(label: "Duration", value: mins < 60 ? "\(mins)m" : "\(mins/60)h\(mins%60)m")
                }
            }
            .padding(.horizontal)

            // Sets grouped by exercise
            let byExercise = Dictionary(grouping: sets) { $0.exercise_id ?? 0 }
            ForEach(byExercise.keys.sorted(), id: \.self) { exerciseId in
                let exSets = byExercise[exerciseId]?.sorted { ($0.set_number ?? 0) < ($1.set_number ?? 0) } ?? []
                if !exSets.isEmpty {
                    exerciseBlock(exerciseId: exerciseId, sets: exSets)
                }
            }
        }
        .padding(.vertical)
    }

    private func exerciseBlock(exerciseId: Int, sets: [ExerciseSet]) -> some View {
        let exerciseName = sets.first?.exercise_name ?? "Exercise #\(exerciseId)"
        return VStack(alignment: .leading, spacing: 8) {
            Text(exerciseName)
                .font(.headline)
                .padding(.horizontal)

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Set").frame(width: 30, alignment: .leading)
                    Spacer()
                    Text("Weight").frame(width: 80, alignment: .trailing)
                    Text("Reps").frame(width: 50, alignment: .trailing)
                    Text("1RM").frame(width: 60, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)

                Divider()

                ForEach(sets) { set in
                    let isDone = set.completed_at != nil
                    let isSkip = set.skipped_at != nil

                    HStack {
                        Text("\(set.set_number ?? 0)")
                            .frame(width: 30, alignment: .leading)
                            .font(.subheadline)
                            .foregroundStyle(isDone ? .primary : .secondary)
                        Spacer()
                        if let w = set.actual_weight_kg, isDone {
                            Text(String(format: "%.0f %@", displayWeight(w), weightUnit))
                                .frame(width: 80, alignment: .trailing)
                                .font(.subheadline.bold())
                        } else {
                            Text("—").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        }
                        if let r = set.actual_reps, isDone {
                            Text("\(r)").frame(width: 50, alignment: .trailing).font(.subheadline)
                        } else {
                            Text(isSkip ? "skip" : "—")
                                .frame(width: 50, alignment: .trailing)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        if let w = set.actual_weight_kg, let r = set.actual_reps, isDone, r > 0 {
                            let rm1 = displayWeight(w * (1 + Double(r) / 30))
                            Text(String(format: "%.0f", rm1))
                                .frame(width: 60, alignment: .trailing)
                                .font(.caption)
                                .foregroundStyle(.blue)
                        } else {
                            Text("—").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(isDone ? Color.clear : Color.secondary.opacity(0.04))

                    Divider().padding(.leading)
                }
            }
        }
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func statBox(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func loadDetail() async {
        guard let sessionId = session.id as Int? else { loading = false; return }
        do {
            detail = try await APIClient.shared.get("/sessions/\(sessionId)")
        } catch {
            print("[SessionDetail] Load error: \(error)")
        }
        loading = false
    }

    private func durationMinutes(from: String, to: String) -> Int {
        let df = ISO8601DateFormatter()
        guard let start = df.date(from: from), let end = df.date(from: to) else { return 0 }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }
}
