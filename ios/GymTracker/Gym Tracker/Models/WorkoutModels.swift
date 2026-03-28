import Foundation

// MARK: - Exercise

struct Exercise: Codable, Identifiable {
    let id: Int
    let display_name: String?
    let movement_type: String?  // "compound" or "isolation"
    let body_region: String?    // "upper", "lower", "full_body"
    let is_unilateral: Bool?
    let is_assisted: Bool?
    let equipment_type: String?
    let primary_muscles: [String]?
    let secondary_muscles: [String]?

    var name: String { display_name ?? "Exercise" }

    /// Primary muscle group for display (e.g. "Chest", "Back")
    var muscle_group: String? {
        primary_muscles?.first?.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Movement category: compound or isolation
    var category: String? { movement_type }
}

// MARK: - Workout Plan

struct PlanExerciseEntry: Codable {
    let exercise_id: Int
    let exercise_name: String?
    let sets: Int?
    let reps: Int?
    let starting_weight_kg: Double?
    let set_type: String?
    let rest_seconds: Int?
    let notes: String?

    var displayName: String { exercise_name ?? "Exercise #\(exercise_id)" }
}

struct PlanDay: Codable, Identifiable {
    var id: Int { day_number }
    let day_number: Int
    let day_name: String
    let exercises: [PlanExerciseEntry]
}

struct WorkoutPlan: Codable, Identifiable {
    let id: Int
    let name: String
    let days: [PlanDay]?
    let number_of_days: Int?
    let description: String?
    let plan_data: String?
    let duration_weeks: Int?
    let current_week: Int?
    let block_type: String?
    let auto_progression: Bool?
    let is_draft: Bool?
    let is_archived: Bool?

    var dayCount: Int { days?.count ?? number_of_days ?? 0 }
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
    let notes: String?
    let sets: [ExerciseSet]?
}

// MARK: - Exercise Set

struct ExerciseSet: Codable, Identifiable {
    let id: Int
    let exercise_id: Int?
    let exercise_name: String?
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
    let food_item_id: Int?
    let meal: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        protein = try c.decodeIfPresent(Double.self, forKey: .protein)
        carbs = try c.decodeIfPresent(Double.self, forKey: .carbs)
        fat = try c.decodeIfPresent(Double.self, forKey: .fat)
        quantity_g = try c.decodeIfPresent(Double.self, forKey: .quantity_g)
        food_item_id = try? c.decodeIfPresent(Int.self, forKey: .food_item_id)
        meal = try? c.decodeIfPresent(String.self, forKey: .meal)
    }
}

struct MacroTotals: Codable {
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct MacroGoals: Codable {
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
    let water_goal_ml: Double?
    // API returns extra fields we can ignore
    let id: Int?
    let effective_from: String?
    let micronutrient_goals: [String: Double]?

    // Manual init for creating from phase goals
    init(calories: Double?, protein: Double?, carbs: Double?, fat: Double?) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.water_goal_ml = nil
        self.id = nil
        self.effective_from = nil
        self.micronutrient_goals = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calories = try c.decodeIfPresent(Double.self, forKey: .calories)
        protein = try c.decodeIfPresent(Double.self, forKey: .protein)
        carbs = try c.decodeIfPresent(Double.self, forKey: .carbs)
        fat = try c.decodeIfPresent(Double.self, forKey: .fat)
        water_goal_ml = try c.decodeIfPresent(Double.self, forKey: .water_goal_ml)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        effective_from = try c.decodeIfPresent(String.self, forKey: .effective_from)
        micronutrient_goals = try c.decodeIfPresent([String: Double].self, forKey: .micronutrient_goals)
    }
}

struct WaterSummary: Codable {
    let date: String
    let total_ml: Double
    let goal_ml: Double
    let entries: [WaterEntryItem]
}

struct WaterEntryItem: Codable, Identifiable {
    let id: Int
    let amount_ml: Double
    let logged_at: String
}

struct DailySummary: Codable {
    let date: String
    let totals: MacroTotals
    let goals: MacroGoals?
    let remaining: MacroGoals?
    let micronutrient_totals: [String: Double]?
}

struct DietPhase: Codable, Identifiable {
    let id: Int
    let phase_type: String // cut, bulk, maintenance
    let started_on: String
    let ended_on: String?
    let is_active: Bool?
    let duration_weeks: Int?
    let starting_weight_kg: Double?
    let target_rate_pct: Double?
    let activity_multiplier: Double?
    let tdee_override: Double?
    let carb_preset: String?
    let body_fat_pct: Double?
    let protein_per_lb: Double?
    // Computed by _build_phase_status
    let current_week: Int?
    let weeks_remaining: Int?
    let current_weight_kg: Double?
    let target_weight_kg: Double?
    let weight_change_kg: Double?
    let actual_rate_pct: Double?
    let status: String?
    let suggestion: String?
    let current_goals: PhaseGoals?
    let tdee_estimate: Double?
}

struct PhaseGoals: Codable {
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

// MARK: - Progress

/// One row from GET /progress/ — one entry per session × exercise
struct ProgressDataPoint: Codable, Identifiable {
    var id: String { "\(exercise_id)_\(date)_\(estimated_1rm ?? 0)_\(volume_load ?? 0)" }
    let exercise_id: Int
    let exercise_name: String
    let date: String          // "YYYY-MM-DD"
    let estimated_1rm: Double?
    let volume_load: Double?
    let recommended_weight: Double?
}

/// GET /progress/recommendations
struct ProgressRecommendation: Codable, Identifiable {
    var id: Int { exercise_id }
    let exercise_id: Int
    let exercise_name: String
    let current_weight: Double?
    let recommended_weight: Double?
    let reason: String?
    let confidence: Double?
}

/// GET /progress/insights (7-day lifestyle insights)
struct ProgressInsight: Codable {
    let exercise_id: Int
    let exercise_name: String
    let estimated_1rm: Double?
    let previous_1rm: Double?
    let trend: String? // up, down, stable
}

struct PersonalRecord: Codable, Identifiable {
    var id: Int { exercise_id }
    let exercise_id: Int
    let display_name: String?
    let name: String?
    let max_weight_kg: Double?
    let max_reps: Int?
    let best_1rm_kg: Double?
    let best_set_weight_kg: Double?
    let best_set_reps: Int?

    var exerciseName: String { display_name ?? name ?? "Exercise #\(exercise_id)" }
}

struct VolumeLandmark: Codable, Identifiable {
    var id: String { muscle }
    let muscle: String
    let sets: Int
    let mev: Int
    let mav: Int
    let mrv: Int
    let status: String // none, below_mev, in_range, above_mav, above_mrv
}

struct VolumeLandmarksResponse: Codable {
    let days: Int
    let muscles: [VolumeLandmark]
    let total_sets: Int
}

// MARK: - Workout Templates

struct WorkoutTemplateExercise: Codable {
    let exercise_id: Int
    let exercise_name: String?
    let sets: Int?
    let reps: Int?
    let starting_weight_kg: Double?
    let progression_type: String?

    var displayName: String { exercise_name ?? "Exercise #\(exercise_id)" }
}

struct WorkoutTemplateDay: Codable {
    let day_number: Int
    let day_name: String
    let exercises: [WorkoutTemplateExercise]
}

struct WorkoutTemplate: Codable, Identifiable {
    let id: Int
    let name: String
    let split_type: String?
    let days_per_week: Int?
    let equipment_tier: String?
    let description: String?
    let block_type: String?
    let exercise_count: Int?
    let days: [WorkoutTemplateDay]?
}

// MARK: - Recipe Models

struct RecipeIngredientModel: Codable, Identifiable {
    let id: Int
    let name: String
    let quantity: Double
    let unit: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct RecipeModel: Codable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let servings: Double
    let total_calories: Double
    let total_protein: Double
    let total_carbs: Double
    let total_fat: Double
    let created_at: String
    let ingredients: [RecipeIngredientModel]?
}

struct RecipeCreateBody: Codable {
    let name: String
    let description: String?
    let servings: Double
    let ingredients: [RecipeIngredientBody]
}

struct RecipeIngredientBody: Codable {
    let name: String
    let quantity: Double
    let unit: String
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double
}

struct RecipeLogBody: Codable {
    let date: String
    let servings: Double
    let meal_type: String
}

// MARK: - Water Tracking

struct WaterSummary: Codable {
    let date: String
    let total_ml: Double
    let goal_ml: Double
    let entries: [WaterEntryItem]
}

struct WaterEntryItem: Codable, Identifiable {
    let id: Int
    let amount_ml: Double
    let logged_at: String
}
