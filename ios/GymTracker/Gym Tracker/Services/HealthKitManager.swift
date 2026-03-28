import Foundation
import HealthKit

/// Centralized HealthKit manager for reading/writing health data.
/// Handles body weight sync, workout logging, and authorization.
@MainActor
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    var isAuthorized = false

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
    func writeWorkout(
        name: String,
        startDate: Date,
        duration: TimeInterval,
        exercises: [UIExercise],
        bodyWeightKg: Double
    ) async {
        guard isAuthorized else { return }

        let totalCalories = estimateCalories(
            exercises: exercises,
            durationSeconds: duration,
            bodyWeightKg: bodyWeightKg
        )

        let calorieQuantity = HKQuantity(
            unit: .kilocalorie(),
            doubleValue: totalCalories
        )

        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: startDate,
            end: startDate.addingTimeInterval(duration),
            workoutEvents: nil,
            totalEnergyBurned: calorieQuantity,
            totalDistance: nil,
            metadata: [
                HKMetadataKeyWorkoutBrandName: "GymTracker",
                "WorkoutName": name,
                "TotalSets": exercises.flatMap(\.sets).filter(\.done).count,
                "TotalVolume": exercises.flatMap(\.sets).filter(\.done).reduce(0.0) { sum, s in
                    sum + (s.weight ?? 0) * Double(s.reps ?? 0)
                },
            ]
        )

        do {
            try await store.save(workout)

            // Also save the active energy burned sample linked to the workout
            let energyType = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!
            let energySample = HKQuantitySample(
                type: energyType,
                quantity: calorieQuantity,
                start: startDate,
                end: startDate.addingTimeInterval(duration)
            )
            try await store.addSamples([energySample], to: workout)

            print("[HealthKit] Saved workout '\(name)': \(Int(totalCalories)) kcal, \(Int(duration / 60)) min")
        } catch {
            print("[HealthKit] Save workout error: \(error)")
        }
    }

    // MARK: - Calorie Estimation

    /// Estimate calories burned using MET values from the Compendium of Physical Activities.
    ///
    /// The estimation works by:
    /// 1. Calculating active time per exercise (sets × avg time per set based on exercise type)
    /// 2. Applying the appropriate MET value based on exercise characteristics
    /// 3. Adding rest period calories at a resting MET of 1.2
    ///
    /// Reference MET values (Ainsworth et al., 2011):
    /// - 06030: Resistance training, free weights (compound): 6.0
    /// - 06050: Resistance training, machines: 3.5
    /// - 02050: Resistance training, bodyweight: 3.8
    /// - 06010: General weight training: 5.0
    func estimateCalories(
        exercises: [UIExercise],
        durationSeconds: TimeInterval,
        bodyWeightKg: Double
    ) -> Double {
        let hours = durationSeconds / 3600.0
        guard hours > 0, bodyWeightKg > 0 else { return 0 }

        // If no exercises (shouldn't happen), use general MET
        guard !exercises.isEmpty else {
            return 5.0 * bodyWeightKg * hours
        }

        // Calculate weighted MET based on exercise composition
        var totalActiveSets = 0
        var weightedMETSum = 0.0

        for exercise in exercises {
            let doneSets = exercise.sets.filter(\.done).count
            guard doneSets > 0 else { continue }

            let met = metForExercise(exercise)
            weightedMETSum += met * Double(doneSets)
            totalActiveSets += doneSets
        }

        guard totalActiveSets > 0 else {
            return 5.0 * bodyWeightKg * hours
        }

        // Weighted average MET across all exercises
        let avgMET = weightedMETSum / Double(totalActiveSets)

        // Estimate active vs rest time
        // Assume ~40 seconds per working set, rest fills the remaining time
        let activeSeconds = min(Double(totalActiveSets) * 40.0, durationSeconds * 0.6)
        let restSeconds = durationSeconds - activeSeconds

        let activeHours = activeSeconds / 3600.0
        let restHours = restSeconds / 3600.0

        // Active calories (exercise MET) + rest calories (standing rest MET ~1.5)
        let activeCal = avgMET * bodyWeightKg * activeHours
        let restCal = 1.5 * bodyWeightKg * restHours

        return max(1, activeCal + restCal)
    }

    /// Determine MET value for an exercise based on its characteristics.
    ///
    /// Uses equipment type, category, and muscle group to assign appropriate MET values:
    /// - Heavy compound barbell movements: 6.0 MET
    /// - Dumbbell compound movements: 5.5 MET
    /// - Machine exercises: 3.5 MET
    /// - Cable exercises: 4.0 MET
    /// - Bodyweight exercises: 3.8 MET
    /// - Isolation free weight: 4.5 MET
    private func metForExercise(_ exercise: UIExercise) -> Double {
        let equipment = exercise.equipmentType.lowercased()
        let category = exercise.category.lowercased()
        let muscle = exercise.muscleGroup.lowercased()

        // Heavy compound barbell lifts (squat, deadlift, bench, OHP, rows)
        if equipment == "barbell" && category == "compound" {
            // Large muscle groups get higher MET
            if muscle == "legs" || muscle == "back" || muscle == "full body" {
                return 6.0  // Heavy squats, deadlifts
            }
            return 5.5  // Bench press, OHP, barbell rows
        }

        // Dumbbell compound movements
        if equipment == "dumbbell" && category == "compound" {
            return 5.0
        }

        // Bodyweight exercises
        if equipment == "bodyweight" || equipment == "body weight" || equipment == "none" {
            if category == "compound" {
                return 4.5  // Pull-ups, dips, push-ups
            }
            return 3.8  // Bodyweight isolation
        }

        // Machine exercises
        if equipment == "machine" || equipment == "smith machine" {
            return 3.5
        }

        // Cable exercises
        if equipment == "cable" {
            return 4.0
        }

        // Isolation with free weights
        if category == "isolation" {
            return 3.5
        }

        // Default: general resistance training
        return 5.0
    }
}
