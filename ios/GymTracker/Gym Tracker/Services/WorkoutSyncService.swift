import Foundation

/// Syncs completed workouts from the backend API to Apple HealthKit.
/// Runs on app launch and can be triggered manually from Settings.
@MainActor
class WorkoutSyncService {
    static let shared = WorkoutSyncService()

    private let syncedKey = "healthkit_synced_session_ids"
    private static let apiDateFormatterWithFractionalSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter
    }()
    private static let apiDateFormatterWithoutFractionalSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private var syncedIds: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: syncedKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: syncedKey) }
    }

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: "healthkit_last_sync") as? Date
    }

    var isSyncEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "healthkit_workout_sync_enabled") == nil {
                return true
            }
            return defaults.bool(forKey: "healthkit_workout_sync_enabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "healthkit_workout_sync_enabled") }
    }

    /// Fetch recent completed sessions and sync unsynced ones to HealthKit
    func syncRecentWorkouts() async {
        guard isSyncEnabled else {
            print("[WorkoutSync] Skipping sync because workout sync is disabled")
            return
        }
        HealthKitManager.shared.checkAuthorization()
        var authorized = HealthKitManager.shared.canWriteWorkouts
        print("[WorkoutSync] Starting recent workout sync. canWriteWorkouts=\(authorized) cachedSyncedCount=\(syncedIds.count)")
        if !authorized {
            print("[WorkoutSync] Requesting HealthKit authorization before workout sync")
            _ = await HealthKitManager.shared.requestAuthorization()
            authorized = HealthKitManager.shared.canWriteWorkouts
        }
        guard authorized else {
            print("[WorkoutSync] Aborting sync because workout write authorization was not granted")
            return
        }

        do {
            // Fetch recent completed sessions
            let sessions: [WorkoutSession] = try await APIClient.shared.get("/sessions/",
                query: [.init(name: "limit", value: "20")])
            let completed = sessions.filter { $0.status == "completed" && $0.completed_at != nil }
            print("[WorkoutSync] Fetched \(sessions.count) recent sessions, \(completed.count) eligible completed sessions")

            var newlySynced = 0
            for session in completed {
                if syncedIds.contains(session.id) {
                    print("[WorkoutSync] Skipping session \(session.id) '\(session.name ?? "Workout")' because it is already marked synced")
                    continue
                }

                let didSync = await writeSessionToHealthKit(session)
                if didSync {
                    syncedIds.insert(session.id)
                    newlySynced += 1
                }
            }

            UserDefaults.standard.set(Date(), forKey: "healthkit_last_sync")
            print("[WorkoutSync] Sync finished. newlySynced=\(newlySynced)")
        } catch {
            print("[WorkoutSync] Error: \(error)")
        }
    }

    private func writeSessionToHealthKit(_ session: WorkoutSession) async -> Bool {
        guard let startStr = session.started_at,
              let start = Self.parseAPITimestamp(startStr) else {
            print("[WorkoutSync] Skipping session \(session.id) '\(session.name ?? "Workout")' because started_at is missing or unparsable: \(session.started_at ?? "nil")")
            return false
        }
        let end: Date
        if let endStr = session.completed_at,
           let parsed = Self.parseAPITimestamp(endStr) {
            end = parsed
        } else {
            print("[WorkoutSync] Session \(session.id) '\(session.name ?? "Workout")' has missing/unparsable completed_at (\(session.completed_at ?? "nil")); defaulting end time to +1 hour")
            end = start.addingTimeInterval(3600) // default 1 hour
        }

        let duration = end.timeIntervalSince(start)
        let totalSets = session.total_sets ?? 0
        let bodyWeightKg = UserDefaults.standard.double(forKey: SettingsKey.lastBodyWeightKg)

        // Simple calorie estimation: avg MET 5.0 for strength training
        let hours = duration / 3600.0
        let calories = max(1, 5.0 * max(bodyWeightKg, 75.0) * hours)
        print("[WorkoutSync] Writing session \(session.id) '\(session.name ?? "Workout")' to HealthKit start=\(start) end=\(end) durationSeconds=\(Int(duration)) sets=\(totalSets) calories=\(Int(calories))")

        return await HealthKitManager.shared.writeWorkoutFromAPI(
            sessionId: session.id,
            name: session.name ?? "Workout",
            startDate: start,
            endDate: end,
            totalCalories: calories,
            totalSets: totalSets,
            totalVolume: session.total_volume_kg ?? 0
        )
    }

    private static func parseAPITimestamp(_ value: String) -> Date? {
        let isoWithFractionalSeconds = ISO8601DateFormatter()
        isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        if let date = isoWithFractionalSeconds.date(from: value) ?? isoBasic.date(from: value) {
            return date
        }

        if let date = apiDateFormatterWithFractionalSeconds.date(from: value)
            ?? apiDateFormatterWithoutFractionalSeconds.date(from: value) {
            return date
        }

        return nil
    }
}
