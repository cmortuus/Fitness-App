"""Adaptive TDEE engine — data-driven energy expenditure estimation.

Uses rolling windows of daily calorie intake and body weight trend data
to back-calculate actual energy expenditure via EWMA smoothing and
linear regression, replacing static formula-based estimates.
"""

import math
from datetime import date, timedelta


def compute_weight_trend(
    weights: list[dict], half_life_days: float = 7.0
) -> list[dict]:
    """Apply exponentially-weighted moving average to smooth weight data.

    Args:
        weights: List of {"date": date, "weight_kg": float}, sorted by date ascending.
        half_life_days: Half-life for EWMA decay (default 7 days).

    Returns:
        Same list with added "trend_kg" field on each entry.
    """
    if not weights:
        return []

    alpha = 1 - math.exp(-math.log(2) / half_life_days)
    result = []
    trend = weights[0]["weight_kg"]

    for i, w in enumerate(weights):
        if i == 0:
            trend = w["weight_kg"]
        else:
            days_gap = (w["date"] - weights[i - 1]["date"]).days
            effective_alpha = 1 - (1 - alpha) ** days_gap
            trend = effective_alpha * w["weight_kg"] + (1 - effective_alpha) * trend
        result.append({**w, "trend_kg": round(trend, 3)})

    return result


def compute_adaptive_tdee(
    daily_records: list[dict],
    window_days: int = 28,
    min_days: int = 14,
    min_intake_days: int = 5,
    min_weigh_days: int = 5,
) -> dict:
    """Compute adaptive TDEE from intake + weight data.

    Args:
        daily_records: List of {"date": date, "intake_calories": float|None, "weight_kg": float|None}.
        window_days: Rolling window size (default 28 days).
        min_days: Minimum days of data before producing adaptive estimate.
        min_intake_days: Minimum days with intake logged.
        min_weigh_days: Minimum days with weight logged.

    Returns:
        {"estimated_tdee": float, "confidence": float, "weight_trend_kg": float|None,
         "avg_intake": float, "method": "adaptive"|"formula"}
    """
    if not daily_records:
        return {
            "estimated_tdee": 0,
            "confidence": 0,
            "weight_trend_kg": None,
            "avg_intake": 0,
            "method": "formula",
        }

    # Filter to window
    cutoff = date.today() - timedelta(days=window_days)
    records = [r for r in daily_records if r["date"] >= cutoff]

    # Separate intake and weight data
    intake_days = [r for r in records if r.get("intake_calories") and r["intake_calories"] > 0]
    weight_days = [r for r in records if r.get("weight_kg") and r["weight_kg"] > 0]

    # Check minimum data requirements
    if len(intake_days) < min_intake_days or len(weight_days) < min_weigh_days or len(records) < min_days:
        avg_intake = sum(r["intake_calories"] for r in intake_days) / max(len(intake_days), 1)
        return {
            "estimated_tdee": round(avg_intake) if avg_intake > 0 else 0,
            "confidence": 0.1,
            "weight_trend_kg": weight_days[-1]["weight_kg"] if weight_days else None,
            "avg_intake": round(avg_intake),
            "method": "formula",
        }

    # Compute EWMA weight trend
    weight_sorted = sorted(weight_days, key=lambda r: r["date"])
    smoothed = compute_weight_trend(
        [{"date": r["date"], "weight_kg": r["weight_kg"]} for r in weight_sorted]
    )

    # Linear regression on smoothed weights to get slope (kg/day)
    if len(smoothed) >= 2:
        n = len(smoothed)
        x_vals = [(s["date"] - smoothed[0]["date"]).days for s in smoothed]
        y_vals = [s["trend_kg"] for s in smoothed]
        x_mean = sum(x_vals) / n
        y_mean = sum(y_vals) / n
        numerator = sum((x - x_mean) * (y - y_mean) for x, y in zip(x_vals, y_vals))
        denominator = sum((x - x_mean) ** 2 for x in x_vals)
        slope = numerator / denominator if denominator > 0 else 0
    else:
        slope = 0

    # Convert slope to daily calorie surplus/deficit
    # 1 kg body weight ≈ 7700 kcal
    daily_surplus = slope * 7700

    # Average daily intake
    avg_intake = sum(r["intake_calories"] for r in intake_days) / len(intake_days)

    # TDEE = intake - surplus (losing weight = negative surplus, so TDEE > intake)
    estimated_tdee = avg_intake - daily_surplus

    # Sanity bounds
    estimated_tdee = max(estimated_tdee, 800)  # minimum physiological TDEE
    estimated_tdee = min(estimated_tdee, 6000)  # maximum reasonable TDEE

    # Confidence score
    data_coverage = min(len(intake_days) / window_days, 1.0)
    weight_coverage = min(len(weight_days) / window_days, 1.0)
    time_factor = min(len(records) / 21, 1.0)
    confidence = min(data_coverage, weight_coverage) * (0.5 + 0.5 * time_factor)

    return {
        "estimated_tdee": round(estimated_tdee),
        "confidence": round(confidence, 2),
        "weight_trend_kg": smoothed[-1]["trend_kg"] if smoothed else None,
        "avg_intake": round(avg_intake),
        "method": "adaptive",
    }


def detect_stall(
    weekly_weight_changes: list[float],
    phase_type: str,
    body_weight_kg: float,
    min_weeks: int = 2,
) -> bool:
    """Detect if weight has stalled during a non-maintenance phase.

    Args:
        weekly_weight_changes: List of weekly weight changes in kg (most recent last).
        phase_type: "cut", "bulk", or "maintenance".
        body_weight_kg: Current body weight for % calculation.
        min_weeks: Minimum consecutive stall weeks to trigger.

    Returns:
        True if stalled for min_weeks consecutive weeks.
    """
    if phase_type == "maintenance" or not weekly_weight_changes or body_weight_kg <= 0:
        return False

    threshold = body_weight_kg * 0.001  # 0.1% of body weight per week
    stall_count = 0
    for change in reversed(weekly_weight_changes):
        if abs(change) < threshold:
            stall_count += 1
        else:
            break

    return stall_count >= min_weeks


def detect_rate_too_fast(
    actual_weekly_rate_pct: float,
    target_weekly_rate_pct: float,
) -> bool:
    """Check if weight change rate exceeds target by >50%.

    Args:
        actual_weekly_rate_pct: Actual weekly weight change as % of body weight.
        target_weekly_rate_pct: Target weekly rate from diet phase.

    Returns:
        True if actual rate is dangerously fast.
    """
    if target_weekly_rate_pct <= 0:
        return False
    return abs(actual_weekly_rate_pct) > abs(target_weekly_rate_pct) * 1.5


def compute_checkin_recommendation(
    adaptive_tdee: float,
    phase_type: str,
    target_rate_pct: float,
    current_weight_kg: float,
    protein_per_lb: float = 1.0,
    carb_preset: str = "moderate",
) -> dict:
    """Generate macro recommendations based on adaptive TDEE.

    Args:
        adaptive_tdee: Data-driven TDEE estimate.
        phase_type: "cut", "bulk", or "maintenance".
        target_rate_pct: Target weekly weight change as % of body weight.
        current_weight_kg: Current body weight.
        protein_per_lb: Protein target per pound of body weight.
        carb_preset: "high", "moderate", or "low".

    Returns:
        {"calories": float, "protein": float, "carbs": float, "fat": float}
    """
    # Calorie target based on phase
    weekly_change_kg = current_weight_kg * (target_rate_pct / 100)
    daily_adjustment = (weekly_change_kg * 7700) / 7  # kcal/day

    if phase_type == "cut":
        target_calories = adaptive_tdee - abs(daily_adjustment)
    elif phase_type == "bulk":
        target_calories = adaptive_tdee + abs(daily_adjustment)
    else:
        target_calories = adaptive_tdee

    target_calories = max(target_calories, 1200)  # safety floor

    # Protein: g per lb of body weight
    weight_lbs = current_weight_kg * 2.20462
    protein_g = round(weight_lbs * protein_per_lb)
    protein_cal = protein_g * 4

    # Fat floor: 20% of calories, minimum 40g
    fat_cal_min = target_calories * 0.20
    fat_g = max(round(fat_cal_min / 9), 40)
    fat_cal = fat_g * 9

    # Carbs: remaining calories
    carbs_cal = target_calories - protein_cal - fat_cal
    if carb_preset == "low":
        # Shift some carb calories to fat
        shift = carbs_cal * 0.2
        carbs_cal -= shift
        fat_cal += shift
        fat_g = round(fat_cal / 9)
    elif carb_preset == "high":
        # Shift some fat calories to carbs
        shift = fat_cal * 0.15
        fat_cal -= shift
        carbs_cal += shift
        fat_g = max(round(fat_cal / 9), 40)

    carbs_g = max(round(carbs_cal / 4), 0)

    return {
        "calories": round(target_calories),
        "protein": protein_g,
        "carbs": carbs_g,
        "fat": fat_g,
    }


def calculate_cycled_macros(
    base_calories: float,
    protein_g: float,
    carb_preset: str,
    training_days_per_week: int,
) -> dict:
    """Calculate training vs rest day macros from a base calorie target.

    Weekly calorie budget is preserved. Training days get ~15% more calories
    (primarily from carbs), rest days get proportionally less.

    Returns:
        {"training": {calories, protein, carbs, fat},
         "rest": {calories, protein, carbs, fat}}
    """
    weekly_budget = base_calories * 7
    rest_days = 7 - training_days_per_week

    # Training days: +15% calories
    training_cal = round(base_calories * 1.15)
    rest_cal = round((weekly_budget - training_cal * training_days_per_week) / max(rest_days, 1))
    rest_cal = max(rest_cal, 1200)

    # Protein stays constant
    protein_cal = protein_g * 4

    # Fat: same on both days (20% of base, min 40g)
    fat_g = max(round(base_calories * 0.20 / 9), 40)
    fat_cal = fat_g * 9

    # Training carbs: extra calories go to carbs
    training_carbs_g = max(round((training_cal - protein_cal - fat_cal) / 4), 0)
    rest_carbs_g = max(round((rest_cal - protein_cal - fat_cal) / 4), 0)

    return {
        "training": {
            "calories": training_cal,
            "protein": protein_g,
            "carbs": training_carbs_g,
            "fat": fat_g,
        },
        "rest": {
            "calories": rest_cal,
            "protein": protein_g,
            "carbs": rest_carbs_g,
            "fat": fat_g,
        },
    }
