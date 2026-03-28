import Foundation
import SwiftUI
import UIKit
import os

// MARK: - App Logger

let appLog = Logger(subsystem: "dev.lethal.gymtracker", category: "app")

// MARK: - UI State Models for Workout

enum SetType: String, CaseIterable {
    case standard = "standard"
    case standardPartials = "standard_partials"
    case warmup = "warmup"
    case myoRep = "myo_rep"
    case myoRepMatch = "myo_rep_match"
    case dropSet = "drop_set"

    var label: String {
        switch self {
        case .standard: return "Straight"
        case .standardPartials: return "+ Partials"
        case .warmup: return "Warmup"
        case .myoRep: return "Myo Rep"
        case .myoRepMatch: return "Myo Match"
        case .dropSet: return "Drop Set"
        }
    }

    var color: Color {
        switch self {
        case .standard: return .primary
        case .standardPartials: return .teal
        case .warmup: return .orange
        case .myoRep: return .purple
        case .myoRepMatch: return .blue
        case .dropSet: return .yellow
        }
    }

    /// Which set types are available for a given set number
    static func available(forSetNumber n: Int) -> [SetType] {
        if n == 1 {
            return [.standard, .standardPartials, .warmup, .myoRep, .dropSet]
        }
        return [.standard, .standardPartials, .warmup, .myoRep, .myoRepMatch, .dropSet]
    }
}

struct UISet: Identifiable {
    let id = UUID()
    var backendId: Int?
    let setNumber: Int
    var weight: Double?
    var reps: Int?
    var repsLeft: Int?
    var repsRight: Int?
    var partialReps: Int?
    var done: Bool
    var doneLeft: Bool = false
    var doneRight: Bool = false
    var skipped: Bool
    var saving: Bool = false
    var setType: SetType
    let exerciseId: Int
    var drops: [DropEntry] = []
    // Initial suggested values (for PR detection)
    var initWeight: Double?
    var initReps: Int?
    // 1RM estimate
    var oneRM: Double?
}

struct DropEntry: Identifiable {
    let id = UUID()
    var weight: Double?
    var reps: Int?
}

struct UIExercise: Identifiable {
    let id: Int // exercise_id
    let name: String
    let muscleGroup: String
    let category: String // compound, isolation
    let isUnilateral: Bool
    let isAssisted: Bool
    let equipmentType: String
    var sets: [UISet]
    var groupId: String? // superset/circuit group
    var customRestSeconds: Int?
    var note: String?
}

extension UISet: Equatable {
    static func == (lhs: UISet, rhs: UISet) -> Bool {
        lhs.weight == rhs.weight && lhs.reps == rhs.reps &&
        lhs.repsLeft == rhs.repsLeft && lhs.repsRight == rhs.repsRight &&
        lhs.partialReps == rhs.partialReps &&
        lhs.done == rhs.done && lhs.doneLeft == rhs.doneLeft && lhs.doneRight == rhs.doneRight &&
        lhs.skipped == rhs.skipped && lhs.saving == rhs.saving &&
        lhs.setType == rhs.setType && lhs.setNumber == rhs.setNumber
    }
}

extension UIExercise: Equatable {
    static func == (lhs: UIExercise, rhs: UIExercise) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.sets == rhs.sets &&
        lhs.groupId == rhs.groupId && lhs.note == rhs.note
    }
}

extension DropEntry: Equatable {
    static func == (lhs: DropEntry, rhs: DropEntry) -> Bool {
        lhs.weight == rhs.weight && lhs.reps == rhs.reps
    }
}

// MARK: - Autoregulation

enum RecoveryRating: String, CaseIterable {
    case poor = "poor"
    case ok = "ok"
    case good = "good"
    case fresh = "fresh"

    var emoji: String {
        switch self {
        case .poor: return "😫"
        case .ok: return "😐"
        case .good: return "😊"
        case .fresh: return "💪"
        }
    }

    var label: String { rawValue.capitalized }
}

enum PumpRating: String, CaseIterable {
    case none = "none"
    case mild = "mild"
    case good = "good"
    case great = "great"

    var emoji: String {
        switch self {
        case .none: return "😶"
        case .mild: return "🙂"
        case .good: return "💪"
        case .great: return "🔥"
        }
    }
}

struct ExerciseFeedback {
    var recovery: RecoveryRating?
    var rir: Int?
    var pump: PumpRating?
    var submitted: Bool = false
}

struct PR {
    let exerciseName: String
    let type: String // "weight" or "reps"
    let value: String
}

// MARK: - Plate Math

struct PlateSlice {
    let weight: Double
    let color: Color
    let heightFraction: CGFloat // relative height (0-1)
    let count: Int
}

// Standard gym plate colors (lbs)
let PLATES_LBS: [(Double, Color, CGFloat)] = [
    (45, .blue,    1.0),
    (35, .yellow,  0.9),
    (25, .green,   0.8),
    (10, .gray,    0.65),
    (5,  .gray,    0.5),
    (2.5, .gray,   0.4),
]

let PLATES_KG: [(Double, Color, CGFloat)] = [
    (25, .red,     1.0),
    (20, .blue,    0.95),
    (15, .yellow,  0.85),
    (10, .green,   0.75),
    (5,  .gray,    0.6),
    (2.5, .gray,   0.5),
    (1.25, .gray,  0.4),
]

func calcPlates(totalWeight: Double, barWeight: Double, isLbs: Bool, oneSided: Bool = false) -> [PlateSlice] {
    let perSide = oneSided ? (totalWeight - barWeight) : (totalWeight - barWeight) / 2
    guard perSide > 0 else { return [] }

    let available = isLbs ? PLATES_LBS : PLATES_KG
    var remaining = perSide
    var result: [PlateSlice] = []

    for (weight, color, height) in available {
        let count = Int(remaining / weight)
        if count > 0 {
            result.append(PlateSlice(weight: weight, color: color, heightFraction: height, count: count))
            remaining -= Double(count) * weight
        }
    }

    if remaining > 0.1 { return [] } // can't make exact weight
    return result
}

// MARK: - Rest Timer Durations

struct RestDurations {
    var upperCompound: Int = 180
    var upperIsolation: Int = 90
    var lowerCompound: Int = 240
    var lowerIsolation: Int = 120

    func duration(for exercise: UIExercise) -> Int {
        if let custom = exercise.customRestSeconds { return custom }
        let isUpper = exercise.muscleGroup == "upper"
        let isCompound = exercise.category == "compound"
        if isUpper && isCompound { return upperCompound }
        if isUpper { return upperIsolation }
        if isCompound { return lowerCompound }
        return lowerIsolation
    }
}

// MARK: - Equipment Helpers

let PLATE_EQUIPMENT = ["barbell", "plate_loaded", "smith_machine"]
let BAR_WEIGHTS: [String: Double] = [
    "barbell": 45,
    "smith_machine": 35,
    "ez_bar": 25,
    "rackable_ez_bar": 25,
    "safety_squat_bar": 65,
    "trap_hex_bar": 55,
    "belt_squat": 0,
]

func shouldShowPlates(for exercise: UIExercise) -> Bool {
    PLATE_EQUIPMENT.contains(exercise.equipmentType)
}

func barWeight(for exercise: UIExercise) -> Double {
    BAR_WEIGHTS[exercise.equipmentType] ?? 45
}

func isOneSided(_ exercise: UIExercise) -> Bool {
    exercise.equipmentType == "t_bar_row" || exercise.name.lowercased().contains("landmine")
}

// MARK: - Keyboard Utilities

/// Dismiss the software keyboard from anywhere
func hideKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}

extension View {
    /// Adds a "Done" button in a toolbar above number/decimal pads
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .fontWeight(.semibold)
            }
        }
    }

    /// Dismiss keyboard when tapping outside text fields
    func dismissKeyboardOnTap() -> some View {
        simultaneousGesture(
            TapGesture().onEnded { hideKeyboard() }
        )
    }
}
