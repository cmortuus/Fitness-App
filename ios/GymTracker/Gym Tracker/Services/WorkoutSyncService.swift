import Foundation

/// Syncs completed workouts from the backend API to Apple HealthKit.
/// Runs on app launch and can be triggered manually from Settings.
@MainActor
class WorkoutSyncService {
    static let shared = WorkoutSyncService()

    private let syncedKey = "healthkit_synced_session_ids"

    private var syncedIds: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: syncedKey) as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: syncedKey) }
    }

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: "healthkit_last_sync") as? Date
    }

    var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "healthkit_workout_sync_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "healthkit_workout_sync_enabled") }
    }

    /// Fetch recent completed sessions and sync unsynced ones to HealthKit
    func syncRecentWorkouts() async {
        guard isSyncEnabled else { return }
        var authorized = HealthKitManager.shared.isAuthorized
        if !authorized {
            authorized = await HealthKitManager.shared.requestAuthorization()
        }
        guard authorized else { return }

        do {
            // Fetch recent completed sessions
            let sessions: [WorkoutSession] = try await APIClient.shared.get("/sessions/",
                query: [.init(name: "limit", value: "20")])
            let completed = sessions.filter { $0.status == "completed" && $0.completed_at != nil }

            var newlySynced = 0
            for session in completed {
                if !syncedIds.contains(session.id) {
                    await writeSessionToHealthKit(session)
                    syncedIds.insert(session.id)
                    newlySynced += 1
                }
            }

            UserDefaults.standard.set(Date(), forKey: "healthkit_last_sync")
            if newlySynced > 0 {
                print("[WorkoutSync] Synced \(newlySynced) workouts to HealthKit")
            }
        } catch {
            print("[WorkoutSync] Error: \(error)")
        }
    }

    private func writeSessionToHealthKit(_ session: WorkoutSession) async {
        // Parse dates
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        guard let startStr = session.started_at,
              let start = iso.date(from: startStr) ?? isoBasic.date(from: startStr) else { return }
        let end: Date
        if let endStr = session.completed_at,
           let parsed = iso.date(from: endStr) ?? isoBasic.date(from: endStr) {
            end = parsed
        } else {
            end = start.addingTimeInterval(3600) // default 1 hour
        }

        let duration = end.timeIntervalSince(start)
        let totalSets = session.total_sets ?? 0
        let bodyWeightKg = UserDefaults.standard.double(forKey: SettingsKey.lastBodyWeightKg)

        // Simple calorie estimation: avg MET 5.0 for strength training
        let hours = duration / 3600.0
        let calories = max(1, 5.0 * max(bodyWeightKg, 75.0) * hours)

        await HealthKitManager.shared.writeWorkoutFromAPI(
            name: session.name ?? "Workout",
            startDate: start,
            endDate: end,
            totalCalories: calories,
            totalSets: totalSets,
            totalVolume: session.total_volume_kg ?? 0
        )
    }
}
