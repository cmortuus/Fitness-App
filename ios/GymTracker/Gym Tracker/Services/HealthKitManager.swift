import Foundation
import HealthKit

/// Centralized HealthKit manager for reading/writing health data.
/// Handles body weight sync, workout logging, and authorization.
final class HealthKitManager: @unchecked Sendable {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    // Protected by MainActor access pattern — only mutated from async functions
    // called from .task modifiers which run on MainActor
    private(set) var isAuthorized = false
    private(set) var isBodyWeightAuthorized = false
    private(set) var isWorkoutAuthorized = false
    private(set) var isEnergyAuthorized = false
    var canWriteWorkouts: Bool { isWorkoutAuthorized && isEnergyAuthorized }

    // MARK: - Types we read/write

    private let typesToWrite: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)!,
    ]

    private let typesToRead: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .bodyMass)!,
        HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
    ]

    // MARK: - Authorization

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private func refreshAuthorizationState() {
        guard isAvailable else {
            isAuthorized = false
            isBodyWeightAuthorized = false
            isWorkoutAuthorized = false
            isEnergyAuthorized = false
            return
        }

        let bodyWeightStatus = store.authorizationStatus(
            for: HKObjectType.quantityType(forIdentifier: .bodyMass)!
        )
        let workoutStatus = store.authorizationStatus(
            for: HKObjectType.workoutType()
        )
        let energyStatus = store.authorizationStatus(
            for: HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
        )

        isBodyWeightAuthorized = (bodyWeightStatus == .sharingAuthorized)
        isWorkoutAuthorized = (workoutStatus == .sharingAuthorized)
        isEnergyAuthorized = (energyStatus == .sharingAuthorized)
        isAuthorized = isBodyWeightAuthorized || canWriteWorkouts
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: typesToWrite, read: typesToRead)
            refreshAuthorizationState()
            print("[HealthKit] Authorization refreshed. bodyWeight=\(isBodyWeightAuthorized) workout=\(isWorkoutAuthorized) energy=\(isEnergyAuthorized)")
            return isAuthorized
        } catch {
            print("[HealthKit] Auth error: \(error)")
            return false
        }
    }

    func checkAuthorization() {
        refreshAuthorizationState()
    }

    // MARK: - Auto Sync

    /// Called on app launch. Reads latest body weight (and body fat % from BIA scales)
    /// from HealthKit and syncs to backend if it's newer than what we have cached.
    func syncBodyWeightOnLaunch() async {
        checkAuthorization()
        guard isBodyWeightAuthorized else { return }

        guard let hkWeight = await readLatestBodyWeight() else { return }

        let cachedWeight = UserDefaults.standard.double(forKey: SettingsKey.lastBodyWeightKg)

        // Only sync if the HealthKit weight differs from cached (tolerance: 0.05 kg)
        if abs(hkWeight - cachedWeight) > 0.05 {
            // Also try to read body fat % (BIA scales write this to HealthKit)
            let bodyFat = await readLatestBodyFatPercentage()

            struct AddBW: Encodable {
                let weight_kg: Double
                let body_fat_pct: Double?
                let notes: String?
            }

            do {
                let _: BodyWeightEntry = try await APIClient.shared.post(
                    "/body-weight/",
                    body: AddBW(
                        weight_kg: hkWeight,
                        body_fat_pct: bodyFat,
                        notes: "Synced from Apple Health"
                    )
                )
                UserDefaults.standard.set(hkWeight, forKey: SettingsKey.lastBodyWeightKg)
                let bfStr = bodyFat.map { String(format: ", BF %.1f%%", $0) } ?? ""
                print("[HealthKit] Auto-synced body weight: \(String(format: "%.1f", hkWeight)) kg\(bfStr)")
            } catch {
                print("[HealthKit] Auto-sync weight error: \(error)")
            }
        }
    }

    /// Read the most recent body fat percentage from HealthKit (from BIA scales, etc.)
    func readLatestBodyFatPercentage() async -> Double? {
        guard isAvailable else { return nil }
        let type = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: Date(), options: .strictEndDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    print("[HealthKit] Read body fat error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                // HealthKit stores body fat as a ratio (0.0-1.0), convert to percentage
                let pct = sample.quantity.doubleValue(for: .percent()) * 100.0
                continuation.resume(returning: pct)
            }
            store.execute(query)
        }
    }

    // MARK: - Body Weight

    /// Write a body weight sample to HealthKit
    func writeBodyWeight(kg: Double, date: Date = Date()) async {
        guard isBodyWeightAuthorized else { return }
        let type = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        do {
            try await store.save(sample)
            // Cache for calorie estimates
            UserDefaults.standard.set(kg, forKey: SettingsKey.lastBodyWeightKg)
            print("[HealthKit] Saved body weight: \(kg) kg")
        } catch {
            print("[HealthKit] Save body weight error: \(error)")
        }
    }

    /// Read the most recent body weight from HealthKit
    func readLatestBodyWeight() async -> Double? {
        guard isAvailable else { return nil }
        let type = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: Date(), options: .strictEndDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    print("[HealthKit] Read body weight error: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                continuation.resume(returning: kg)
            }
            store.execute(query)
        }
    }

    /// Read body weight history from HealthKit (last N days)
    func readBodyWeightHistory(days: Int = 90) async -> [(date: Date, kg: Double)] {
        guard isAvailable else { return [] }
        let type = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictEndDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    print("[HealthKit] Read weight history error: \(error)")
                    continuation.resume(returning: [])
                    return
                }
                let results = (samples as? [HKQuantitySample] ?? []).map { sample in
                    (date: sample.startDate,
                     kg: sample.quantity.doubleValue(for: .gramUnit(with: .kilo)))
                }
                continuation.resume(returning: results)
            }
            store.execute(query)
        }
    }

    // MARK: - Workout

    /// Write a completed workout to HealthKit with calorie estimation.
    ///
    /// Calorie estimation uses the Compendium of Physical Activities MET values:
    /// - Compound free-weight exercises (squat, deadlift, bench): MET 6.0
    /// - Isolation/machine exercises: MET 3.5
    /// - General strength training average: MET 5.0
    /// - Bodyweight exercises: MET 3.8
    ///
    /// Formula: kcal = MET × bodyWeightKg × durationHours
    /// Write a workout from API session data to HealthKit
    func writeWorkoutFromAPI(
        sessionId: Int? = nil,
        name: String,
        startDate: Date,
        endDate: Date,
        totalCalories: Double,
        totalSets: Int,
        totalVolume: Double
    ) async -> Bool {
        guard canWriteWorkouts else {
            print("[HealthKit] Refusing workout sync for session \(sessionId.map(String.init) ?? "?") because workout authorization is incomplete. workout=\(isWorkoutAuthorized) energy=\(isEnergyAuthorized)")
            return false
        }

        let calorieQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: totalCalories)

        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining

        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)

        do {
            print("[HealthKit] Saving workout session \(sessionId.map(String.init) ?? "?") '\(name)' start=\(startDate) end=\(endDate) totalSets=\(totalSets) totalVolumeKg=\(totalVolume)")

            try await builder.beginCollection(at: startDate)

            // Add only the calorie sample — no heart rate samples attached
            let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
            let energySample = HKQuantitySample(
                type: energyType,
                quantity: calorieQuantity,
                start: startDate,
                end: endDate
            )
            try await builder.addSamples([energySample])

            try await builder.endCollection(at: endDate)

            // Add metadata before finishing
            try await builder.addMetadata([
                HKMetadataKeyWorkoutBrandName: "Onyx Expenditure",
                "WorkoutName": name,
                "TotalSets": totalSets,
                "TotalVolumeKg": totalVolume,
            ])

            try await builder.finishWorkout()

            print("[HealthKit] Synced workout session \(sessionId.map(String.init) ?? "?") '\(name)': \(Int(totalCalories)) kcal")
            return true
        } catch {
            print("[HealthKit] Save workout error for session \(sessionId.map(String.init) ?? "?") '\(name)': \(error)")
            return false
        }
    }

    /// Delete workouts previously written by this app across legacy and current brand names.
    func deleteAllGymTrackerWorkouts() async -> Int {
        guard canWriteWorkouts else {
            print("[HealthKit] Cannot delete workouts — no write authorization")
            return 0
        }

        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyWorkoutBrandName,
            allowedValues: ["GymTracker", "Onyx Intake", "Onyx Expenditure"]
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
                guard let self, let workouts = samples as? [HKWorkout], error == nil else {
                    print("[HealthKit] Error querying workouts for deletion: \(error?.localizedDescription ?? "unknown")")
                    continuation.resume(returning: 0)
                    return
                }

                print("[HealthKit] Found \(workouts.count) branded workouts to delete")
                guard !workouts.isEmpty else {
                    continuation.resume(returning: 0)
                    return
                }

                Task {
                    var deletedWorkoutCount = 0

                    do {
                        for workout in workouts {
                            let deleted = try await self.deleteWorkoutAndSamples(workout)
                            if deleted {
                                deletedWorkoutCount += 1
                            }
                        }
                        print("[HealthKit] Deleted \(deletedWorkoutCount) branded workouts and their samples")
                        continuation.resume(returning: deletedWorkoutCount)
                    } catch {
                        print("[HealthKit] Error deleting workouts: \(error.localizedDescription)")
                        continuation.resume(returning: deletedWorkoutCount)
                    }
                }
            }
            store.execute(query)
        }
    }

    private func deleteWorkoutAndSamples(_ workout: HKWorkout) async throws -> Bool {
        let energySamples = try await loadEnergySamplesForDeletion(workout: workout)
        if !energySamples.isEmpty {
            try await store.delete(energySamples)
        }
        try await store.delete(workout)
        return true
    }

    private func loadEnergySamplesForDeletion(workout: HKWorkout) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
            let query = HKSampleQuery(
                sampleType: energyType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            self.store.execute(query)
        }
    }
}
