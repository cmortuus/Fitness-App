import Foundation

/// Represents the current workout state sent from the phone app
struct WorkoutState: Codable {
    let sessionId: Int
    let workoutName: String
    let exercises: [WatchExercise]
    let currentExerciseIndex: Int
    let currentSetIndex: Int
    let elapsed: Int // seconds since workout started
    let restActive: Bool
    let restSecs: Int
}

struct WatchExercise: Codable, Identifiable {
    let id: Int // exercise_id
    let name: String
    let sets: [WatchSet]
}

struct WatchSet: Codable, Identifiable {
    let id: String // localId
    let setNumber: Int
    let weight: Double? // in user's unit (lbs or kg)
    let reps: Int?
    let done: Bool
    let skipped: Bool
    let unit: String // "lbs" or "kg"
}

/// Message sent from Watch to Phone when completing a set
struct SetCompleteMessage: Codable {
    let exerciseId: Int
    let setLocalId: String
    let action: String // "complete" or "skip"
}

/// Message sent from Watch to Phone to skip rest
struct RestSkipMessage: Codable {
    let action: String // "skipRest"
}
