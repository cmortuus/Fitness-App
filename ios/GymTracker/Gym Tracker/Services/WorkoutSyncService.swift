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

    /// Clear all synced state so every workout re-syncs on next launch
    func resetSyncState() {
        syncedIds = []
        UserDefaults.standard.removeObject(forKey: "healthkit_last_sync")
        print("[WorkoutSync] Reset sync state — all workouts will re-sync")
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
        let bodyWeightKg = max(UserDefaults.standard.double(forKey: SettingsKey.lastBodyWeightKg), 75.0)

        let result = estimateCalories(session: session, bodyWeightKg: bodyWeightKg)
        let calories = result.total
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

    // MARK: - Calorie Estimation

    /// MET value for a set based on exercise metadata
    private func metForSet(_ set: ExerciseSet) -> Double {
        let isCompound = set.movement_type == "compound"
        let equipType = set.equipment_type ?? "other"
        let freeWeight = ["barbell", "dumbbell", "kettlebell"].contains(equipType)
        let plateLoaded = equipType == "plate_loaded"
        let isWarmup = set.set_type == "warmup"

        let baseMET: Double
        if set.movement_type == nil {
            // No metadata — fallback
            baseMET = 5.0
        } else if isCompound {
            if freeWeight { baseMET = 6.0 }
            else if plateLoaded { baseMET = 5.5 }
            else { baseMET = 5.0 }
        } else {
            // Isolation
            if freeWeight { baseMET = 4.0 }
            else { baseMET = 3.5 }
        }

        return isWarmup ? baseMET * 0.6 : baseMET
    }

    /// Seconds per rep based on movement type
    private func secsPerRep(isCompound: Bool) -> Double {
        isCompound ? 3.0 : 2.0
    }

    /// Estimate calories for a workout session using per-set MET calculations
    func estimateCalories(session: WorkoutSession, bodyWeightKg: Double) -> (total: Double, active: Double, rest: Double, epoc: Double) {
        let sets = (session.sets ?? []).filter {
            ($0.actual_reps ?? 0) > 0 && $0.skipped_at == nil
        }

        // Parse session duration
        let sessionDuration: Double // seconds
        if let startStr = session.started_at, let endStr = session.completed_at,
           let start = Self.parseAPITimestamp(startStr), let end = Self.parseAPITimestamp(endStr) {
            sessionDuration = min(end.timeIntervalSince(start), 3 * 3600) // cap 3 hours
        } else {
            // Fallback: estimate from set count
            sessionDuration = Double(max(sets.count, 1)) * 120 // ~2 min per set avg
        }
        let clampedDuration = max(sessionDuration, 300) // min 5 minutes

        guard !sets.isEmpty else {
            // No set data — fall back to flat MET 5.0
            let hours = clampedDuration / 3600.0
            let total = max(1, 5.0 * bodyWeightKg * hours)
            return (total, total, 0, 0)
        }

        // Active calories: sum per-set MET × bodyWeight × setDuration
        var totalActiveSeconds: Double = 0
        var activeCalories: Double = 0
        var compoundSets = 0
        var isolationSets = 0

        for set in sets {
            let reps = Double(set.actual_reps ?? 0)
            let isCompound = set.movement_type == "compound"
            let setDuration = reps * secsPerRep(isCompound: isCompound)
            let met = metForSet(set)

            activeCalories += met * bodyWeightKg * (setDuration / 3600.0)
            totalActiveSeconds += setDuration

            if isCompound { compoundSets += 1 } else { isolationSets += 1 }
        }

        // Rest calories: resting MET 1.2 for time between sets
        let restSeconds = max(clampedDuration - totalActiveSeconds, 0)
        let restCalories = 1.2 * bodyWeightKg * (restSeconds / 3600.0)

        // EPOC bonus based on session intensity (volume / minutes)
        let totalMinutes = clampedDuration / 60.0
        let volumeKg = session.total_volume_kg ?? 0
        let intensityPerMin = totalMinutes > 0 ? volumeKg / totalMinutes : 0
        let epocMultiplier: Double
        if intensityPerMin > 60 { epocMultiplier = 0.15 }
        else if intensityPerMin > 30 { epocMultiplier = 0.10 }
        else { epocMultiplier = 0.06 }
        let epocCalories = activeCalories * epocMultiplier

        let total = max(1.0, activeCalories + restCalories + epocCalories)

        print("[WorkoutSync] Calorie breakdown for session \(session.id): "
            + "active=\(Int(activeCalories)) rest=\(Int(restCalories)) "
            + "epoc=\(Int(epocCalories)) total=\(Int(total)) "
            + "compound=\(compoundSets) isolation=\(isolationSets) "
            + "activeTime=\(Int(totalActiveSeconds))s restTime=\(Int(restSeconds))s "
            + "intensity=\(Int(intensityPerMin))kg/min")

        return (total, activeCalories, restCalories, epocCalories)
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
