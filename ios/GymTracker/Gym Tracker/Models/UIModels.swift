import Foundation
import SwiftUI
import UIKit
import os

// MARK: - App Logger

let appLog = Logger(subsystem: "dev.lethal.gymtracker", category: "app")

// MARK: - App Constants

enum AppConstants {
    static let plateTolerance: Double = 0.1
    static let estimatedSecondsPerSet: Double = 40.0
    static let settingsSyncDebounceMs: UInt64 = 500
    static let searchDebounceMs: UInt64 = 300
    static let defaultBarWeightLbs: Double = 45.0
    static let defaultBarWeightKg: Double = 20.0
    static let minTapTarget: CGFloat = 44.0
    static let cardCornerRadius: CGFloat = 16.0  // matches web rounded-2xl
    static let darkCardBackground = Color(white: 0.11)
}

// MARK: - Design System (matching web Tailwind zinc palette)

enum AppColors {
    // Zinc palette — matches Tailwind zinc scale
    static let zinc950 = Color(red: 0.055, green: 0.055, blue: 0.063)  // bg
    static let zinc900 = Color(red: 0.094, green: 0.094, blue: 0.106)  // card
    static let zinc800 = Color(red: 0.153, green: 0.153, blue: 0.169)  // card-elevated, inputs
    static let zinc700 = Color(red: 0.247, green: 0.247, blue: 0.267)  // borders
    static let zinc600 = Color(red: 0.329, green: 0.329, blue: 0.353)  // input borders
    static let zinc500 = Color(red: 0.443, green: 0.443, blue: 0.471)  // muted text
    static let zinc400 = Color(red: 0.631, green: 0.631, blue: 0.659)  // secondary text
    static let zinc300 = Color(red: 0.831, green: 0.831, blue: 0.847)  // primary text
    static let zinc100 = Color(red: 0.953, green: 0.953, blue: 0.961)  // bright text

    // Accent colors
    static let primary = Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)   // #8b5cf6
}

extension View {
    /// Standard card style — matches web `.card` class (zinc-900, rounded-2xl, 1px zinc-800 border)
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(AppColors.zinc900)
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius)
                    .strokeBorder(AppColors.zinc800, lineWidth: 1)
            )
    }

    /// Elevated card style — matches web `.card-elevated` (zinc-800, shadow)
    func cardElevatedStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(AppColors.zinc800)
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppConstants.cardCornerRadius)
                    .strokeBorder(AppColors.zinc700, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    /// Input field style — matches web `.set-input` (zinc-800, zinc-600 border, rounded-lg)
    func inputStyle() -> some View {
        self
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(height: 48)
            .background(AppColors.zinc800)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppColors.zinc600, lineWidth: 1)
            )
    }
}

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
