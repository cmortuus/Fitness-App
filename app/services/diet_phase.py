"""Diet phase calculation helpers — TDEE, macro splits, weekly adjustments.

All pure functions, no DB access. Science-based defaults:
  - Protein based on lean body mass when body fat % is known
  - Cuts: 0.5-1% BW loss/week
  - Bulks: 0.25-0.5% BW gain/week
  - 7700 kcal ≈ 1 kg of body fat
"""

from __future__ import annotations

KG_TO_LBS = 2.20462
CAL_PER_KG_FAT = 7700  # approximate kcal energy in 1 kg body fat

# Default protein targets (g per lb) — used when no body fat estimate given
DEFAULT_PROTEIN = {
    "cut": 1.0,
    "bulk": 0.8,
    "maintenance": 0.8,
}

# Protein per lb of LEAN mass — used when body fat % is known
LEAN_PROTEIN = {
    "cut": 1.2,       # higher per lb of lean mass to preserve muscle
    "bulk": 1.0,
    "maintenance": 1.0,
}

# Minimum fat floor (g per lb of body weight) for hormonal health
MIN_FAT_PER_LB = 0.3

# Carb/fat split ratios (of remaining cals after protein)
CARB_SPLITS = {
    "high":     (0.60, 0.40),
    "moderate": (0.50, 0.50),
    "low":      (0.30, 0.70),
}


def estimate_tdee(
    weight_kg: float,
    activity_multiplier: float,
    tdee_override: float | None = None,
    body_fat_pct: float | None = None,
) -> float:
    """Estimate total daily energy expenditure.

    Uses Katch-McArdle (if body fat % known) or a conservative cal/lb formula.
    Activity multiplier maps to standard TDEE multipliers:
      1.0 Sedentary   → ×1.2
      1.2 Light       → ×1.375
      1.4 Moderate    → ×1.55
      1.6 Active      → ×1.725
      1.8 Very Active → ×1.9
    Returns tdee_override if provided (user knows their maintenance).
    """
    if tdee_override and tdee_override > 0:
        return tdee_override

    # Map our 1.0-1.8 scale to standard TDEE multipliers
    tdee_multipliers = {1.0: 1.2, 1.2: 1.375, 1.4: 1.55, 1.6: 1.725, 1.8: 1.9}
    mult = tdee_multipliers.get(activity_multiplier, 1.55)

    if body_fat_pct and 5 <= body_fat_pct <= 60:
        # Katch-McArdle: BMR = 370 + (21.6 × lean mass in kg)
        lean_kg = weight_kg * (1 - body_fat_pct / 100)
        bmr = 370 + (21.6 * lean_kg)
    else:
        # Cunningham-style estimate assuming ~25% body fat as default
        # This gives more realistic numbers for higher body weights
        estimated_lean = weight_kg * 0.75
        bmr = 370 + (21.6 * estimated_lean)

    return round(bmr * mult)


def calculate_macros(
    weight_kg: float,
    phase_type: str,
    target_rate_pct: float,
    activity_multiplier: float = 1.4,
    tdee_override: float | None = None,
    carb_preset: str = "moderate",
    body_fat_pct: float | None = None,
    protein_per_lb: float | None = None,
) -> dict:
    """Calculate daily macro targets for a given phase.

    Protein priority:
      1. protein_per_lb if explicitly set by user (g per lb of body weight)
      2. body_fat_pct → lean mass × lean protein factor
      3. fallback: total body weight × default factor

    Returns dict with calories, protein, carbs, fat (all rounded).
    """
    tdee = estimate_tdee(weight_kg, activity_multiplier, tdee_override, body_fat_pct)
    weight_lbs = weight_kg * KG_TO_LBS

    # Daily calorie adjustment from target rate
    weekly_change_kg = weight_kg * (target_rate_pct / 100)
    daily_change_cal = (weekly_change_kg * CAL_PER_KG_FAT) / 7

    if phase_type == "cut":
        target_calories = tdee - daily_change_cal
    elif phase_type == "bulk":
        target_calories = tdee + daily_change_cal
    else:  # maintenance
        target_calories = tdee

    target_calories = round(max(1200, target_calories))  # safety floor

    # Protein calculation
    if protein_per_lb is not None and protein_per_lb > 0:
        # User explicitly set their protein target
        protein_g = round(weight_lbs * protein_per_lb)
    elif body_fat_pct is not None and 5 <= body_fat_pct <= 60:
        # Calculate from lean body mass
        lean_lbs = weight_lbs * (1 - body_fat_pct / 100)
        factor = LEAN_PROTEIN.get(phase_type, 1.0)
        protein_g = round(lean_lbs * factor)
    else:
        # Fallback: total body weight × conservative default
        factor = DEFAULT_PROTEIN.get(phase_type, 0.8)
        protein_g = round(weight_lbs * factor)

    # Carb/fat split
    protein_cals = protein_g * 4
    remaining_cals = max(0, target_calories - protein_cals)
    carb_ratio, fat_ratio = CARB_SPLITS.get(carb_preset, CARB_SPLITS["moderate"])

    fat_g = round(remaining_cals * fat_ratio / 9)
    carbs_g = round(remaining_cals * carb_ratio / 4)

    # Fat floor: never below 0.3 g/lb for hormonal health
    min_fat = round(weight_lbs * MIN_FAT_PER_LB)
    if fat_g < min_fat:
        fat_g = min_fat
        fat_cals = fat_g * 9
        carbs_g = round(max(0, remaining_cals - fat_cals) / 4)

    return {
        "calories": target_calories,
        "protein": protein_g,
        "carbs": carbs_g,
        "fat": fat_g,
        "tdee_estimate": round(tdee),
    }


def target_end_weight(starting_kg: float, phase_type: str, rate_pct: float, weeks: int) -> float:
    """Project end weight based on phase parameters."""
    weekly_change = starting_kg * (rate_pct / 100)
    if phase_type == "cut":
        return round(starting_kg - weekly_change * weeks, 1)
    elif phase_type == "bulk":
        return round(starting_kg + weekly_change * weeks, 1)
    return starting_kg


def weight_trend(entries: list, window: int = 7) -> float | None:
    """Return the moving average of the most recent `window` weigh-ins."""
    if not entries:
        return None
    recent = sorted(entries, key=lambda e: e.recorded_at, reverse=True)[:window]
    return round(sum(e.weight_kg for e in recent) / len(recent), 2)


def weekly_adjustment(
    current_avg: float | None,
    previous_avg: float | None,
    phase_type: str,
    target_rate_pct: float,
) -> dict:
    """Determine if the user is on track and suggest calorie adjustments.

    Returns {status, actual_rate_pct, suggestion, cal_adjustment}.
    """
    if current_avg is None or previous_avg is None or previous_avg <= 0:
        return {"status": "no_data", "actual_rate_pct": None, "suggestion": "Log more weigh-ins for tracking.", "cal_adjustment": 0}

    # Actual weekly rate of change (% of body weight)
    change_kg = previous_avg - current_avg  # positive = weight loss
    if phase_type == "bulk":
        change_kg = -change_kg  # for bulks, positive = weight gain
    actual_rate = abs(change_kg / previous_avg * 100)

    tolerance = 0.15  # % threshold before suggesting changes

    if abs(actual_rate - target_rate_pct) <= tolerance:
        return {"status": "on_track", "actual_rate_pct": round(actual_rate, 2), "suggestion": None, "cal_adjustment": 0}

    if actual_rate < target_rate_pct - tolerance:
        # Not losing/gaining fast enough
        adj = -150 if phase_type == "cut" else 100
        verb = "reducing" if phase_type == "cut" else "increasing"
        return {
            "status": "behind",
            "actual_rate_pct": round(actual_rate, 2),
            "suggestion": f"Progress is slower than target. Consider {verb} calories by ~{abs(adj)}.",
            "cal_adjustment": adj,
        }

    # Losing/gaining too fast
    adj = 150 if phase_type == "cut" else -100
    verb = "increasing" if phase_type == "cut" else "reducing"
    return {
        "status": "ahead",
        "actual_rate_pct": round(actual_rate, 2),
        "suggestion": f"Progress is faster than target. Consider {verb} calories by ~{abs(adj)} to preserve muscle.",
        "cal_adjustment": adj,
    }
