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

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: typesToWrite, read: typesToRead)
            let status = store.authorizationStatus(
                for: HKObjectType.quantityType(forIdentifier: .bodyMass)!)
            isAuthorized = (status == .sharingAuthorized)
            return isAuthorized
        } catch {
            print("[HealthKit] Auth error: \(error)")
            return false
        }
    }

    func checkAuthorization() {
        guard isAvailable else { return }
        let status = store.authorizationStatus(
            for: HKObjectType.quantityType(forIdentifier: .bodyMass)!)
        isAuthorized = (status == .sharingAuthorized)
    }

    // MARK: - Auto Sync

    /// Called on app launch. Reads latest body weight (and body fat % from BIA scales)
    /// from HealthKit and syncs to backend if it's newer than what we have cached.
    func syncBodyWeightOnLaunch() async {
        checkAuthorization()
        guard isAuthorized else { return }

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
        guard isAuthorized else { return }
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
        name: String,
        startDate: Date,
        endDate: Date,
        totalCalories: Double,
        totalSets: Int,
        totalVolume: Double
    ) async {
        guard isAuthorized else { return }

        let calorieQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: totalCalories)

        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: startDate,
            end: endDate,
            workoutEvents: nil,
            totalEnergyBurned: calorieQuantity,
            totalDistance: nil,
            metadata: [
                HKMetadataKeyWorkoutBrandName: "Onyx Intake",
                "WorkoutName": name,
                "TotalSets": totalSets,
                "TotalVolumeKg": totalVolume,
            ]
        )

        do {
            try await store.save(workout)

            let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
            let energySample = HKQuantitySample(
                type: energyType,
                quantity: calorieQuantity,
                start: startDate,
                end: endDate
            )
            try await store.addSamples([energySample], to: workout)

            print("[HealthKit] Synced workout '\(name)': \(Int(totalCalories)) kcal")
        } catch {
            print("[HealthKit] Save workout error: \(error)")
        }
    }
}
