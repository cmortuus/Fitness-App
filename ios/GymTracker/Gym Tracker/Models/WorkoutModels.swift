import Foundation

// MARK: - Exercise

struct Exercise: Codable, Identifiable {
    let id: Int
    let display_name: String?
    let category: String?
    let muscle_group: String?
    let movement_type: String?
    let is_unilateral: Bool?
    let is_assisted: Bool?
    let equipment_type: String?

    var name: String { display_name ?? "Exercise" }
}

// MARK: - Workout Plan

struct WorkoutPlan: Codable, Identifiable {
    let id: Int
    let name: String
    let days: AnyCodable? // Can be Int or Array depending on endpoint
    let description: String?
    let plan_data: String? // JSON string
    let duration_weeks: Int?
    let current_week: Int?
    let block_type: String?
    let auto_progression: Bool?

    var dayCount: Int {
        switch days {
        case .int(let n): return n
        case .array(let arr): return arr.count
        case .none: return 0
        }
    }
}

/// Handles fields that can be either Int or Array in JSON
enum AnyCodable: Codable {
    case int(Int)
    case array([[String: AnyCodableValue]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let arrVal = try? container.decode([[String: AnyCodableValue]].self) {
            self = .array(arrVal)
        } else {
            self = .int(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let n): try container.encode(n)
        case .array(let arr): try container.encode(arr)
        }
    }
}

/// Generic JSON value for flexible decoding
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Workout Session

struct WorkoutSession: Codable, Identifiable {
    let id: Int
    let user_id: Int?
    let workout_plan_id: Int?
    let name: String?
    let date: String?
    let status: String // planned, in_progress, completed
    let total_volume_kg: Double?
    let total_sets: Int?
    let total_reps: Int?
    let started_at: String?
    let completed_at: String?
    let day_number: Int?
    let sets: [ExerciseSet]?
}

// MARK: - Exercise Set

struct ExerciseSet: Codable, Identifiable {
    let id: Int
    let exercise_id: Int?
    let set_number: Int?
    let planned_reps: Int?
    let planned_weight_kg: Double?
    let actual_reps: Int?
    let actual_weight_kg: Double?
    let reps_left: Int?
    let reps_right: Int?
    let notes: String?
    let completed_at: String?
    let skipped_at: String?
    let set_type: String?
    let sub_sets: [SubSet]?
    let draft_weight_kg: Double?
    let draft_reps: Int?
    let draft_reps_left: Int?
    let draft_reps_right: Int?
    let planned_reps_left: Int?
    let planned_reps_right: Int?
}

struct SubSet: Codable {
    let weight_kg: Double?
    let reps: Int?
    let type: String?
}

// MARK: - Create/Update DTOs

struct CreateSetRequest: Encodable {
    let exercise_id: Int
    let set_number: Int
    let planned_reps: Int?
    let planned_weight_kg: Double?
    let set_type: String?
}

struct UpdateSetRequest: Encodable {
    let actual_reps: Int?
    let actual_weight_kg: Double?
    let completed_at: String?
    let reps_left: Int?
    let reps_right: Int?
    let notes: String?
    let set_type: String?
    let sub_sets: [SubSet]?
    let draft_weight_kg: Double?
    let draft_reps: Int?
}

// MARK: - Body Weight

struct BodyWeightEntry: Codable, Identifiable {
    let id: Int
    let user_id: Int?
    let weight_kg: Double
    let body_fat_pct: Double?
    let notes: String?
    let recorded_at: String?
}

// MARK: - Nutrition

struct NutritionEntry: Codable, Identifiable {
    let id: Int
    let name: String
    let date: String?
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let quantity_g: Double?
}

struct DailySummary: Codable {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let entries: [NutritionEntry]
}

struct DietPhase: Codable, Identifiable {
    let id: Int
    let phase_type: String // cut, bulk, maintenance
    let start_date: String
    let end_date: String?
    let is_active: Bool
    let target_calories: Double?
    let target_protein: Double?
    let target_carbs: Double?
    let target_fat: Double?
}

// MARK: - Progress

struct ProgressInsight: Codable {
    let exercise_id: Int
    let exercise_name: String
    let estimated_1rm: Double?
    let previous_1rm: Double?
    let trend: String? // up, down, stable
}

struct PersonalRecord: Codable {
    let exercise_id: Int
    let exercise_name: String
    let best_weight_kg: Double?
    let best_reps: Int?
    let best_1rm: Double?
    let date: String?
}
