"""
Progressive Overload Calculator

Determines next weight and reps for any exercise based on:
- Current performance (weight × reps)
- Historical baseline
- Rolling e1RM trend across recent sessions
- Exercise type (compound vs isolation)
- User training level

Uses Epley formula: e1RM = weight × (1 + reps / 30)
"""

from dataclasses import dataclass
from typing import Optional


@dataclass
class OverloadInput:
    """Input for the overload calculator."""
    current_weight: float       # Current working weight (in user's unit)
    current_reps: int           # Current reps achieved
    baseline_weight: float      # Starting weight for this progression cycle
    baseline_reps: int          # Starting reps for this progression cycle
    target_reps: Optional[int]  # Preferred rep target (None = auto)
    exercise_type: str          # "compound" or "isolation"
    training_level: str         # "beginner", "intermediate", "advanced"
    rolling_e1rm_trend: float   # Average e1RM change over last 3-5 sessions (positive = gaining)
    weight_increment: float     # Minimum weight increment (5 lbs or 2.5 kg)


@dataclass
class OverloadResult:
    """Output from the overload calculator."""
    next_weight: float
    next_reps: int
    strategy: str              # "weight_up", "reps_up", "hold", "deload"
    confidence: str            # "high", "medium", "low"
    explanation: str           # Human-readable explanation
    estimated_1rm: float       # Current estimated 1RM
    projected_1rm: float       # Projected 1RM with new weight/reps


def calculate_overload(inp: OverloadInput) -> OverloadResult:
    """
    Calculate the next weight and reps for progressive overload.

    The algorithm:
    1. Estimate current capacity via Epley 1RM
    2. Determine if strength gain exceeds noise threshold
    3. Project weight for target reps (or choose strategy)
    4. Apply increment caps by exercise type and training level
    5. Use systemic trend to modulate aggression
    """

    # 1. Estimate current and baseline 1RM
    current_e1rm = epley_1rm(inp.current_weight, inp.current_reps)
    baseline_e1rm = epley_1rm(inp.baseline_weight, inp.baseline_reps)
    strength_gain = current_e1rm - baseline_e1rm

    # Noise threshold — don't progress on tiny fluctuations
    noise_threshold = current_e1rm * 0.02  # 2% of current 1RM

    # 2. Determine base increment caps by type and level
    max_weight_increment = _max_increment(inp.exercise_type, inp.training_level, inp.weight_increment)
    max_reps_increment = _max_reps_increment(inp.exercise_type)

    # 3. Determine target reps
    target_reps = inp.target_reps or inp.current_reps

    # 4. Calculate progression
    if strength_gain < -noise_threshold:
        # Performance declining — suggest hold or deload
        if strength_gain < -noise_threshold * 3:
            return OverloadResult(
                next_weight=round_to_increment(inp.current_weight * 0.9, inp.weight_increment),
                next_reps=inp.current_reps,
                strategy="deload",
                confidence="high",
                explanation=f"Performance declining ({strength_gain:.1f} lbs e1RM). Reduce weight 10% and rebuild.",
                estimated_1rm=current_e1rm,
                projected_1rm=current_e1rm * 0.9,
            )
        return OverloadResult(
            next_weight=inp.current_weight,
            next_reps=inp.current_reps,
            strategy="hold",
            confidence="medium",
            explanation="Performance dipped slightly. Repeat this weight/rep combo.",
            estimated_1rm=current_e1rm,
            projected_1rm=current_e1rm,
        )

    if strength_gain < noise_threshold:
        # Within noise — try adding reps first (rep-first progression)
        if inp.current_reps < target_reps + max_reps_increment:
            new_reps = min(inp.current_reps + 1, target_reps + max_reps_increment)
            new_e1rm = epley_1rm(inp.current_weight, new_reps)
            return OverloadResult(
                next_weight=inp.current_weight,
                next_reps=new_reps,
                strategy="reps_up",
                confidence="medium",
                explanation=f"Add 1 rep ({inp.current_reps} → {new_reps}). Same weight.",
                estimated_1rm=current_e1rm,
                projected_1rm=new_e1rm,
            )
        # At rep ceiling — hold
        return OverloadResult(
            next_weight=inp.current_weight,
            next_reps=inp.current_reps,
            strategy="hold",
            confidence="low",
            explanation="At rep ceiling. Hold until next session confirms progress.",
            estimated_1rm=current_e1rm,
            projected_1rm=current_e1rm,
        )

    # 5. Meaningful strength gain — progress!
    # Calculate trend bonus (systemic adaptation signal)
    trend_bonus = 0.0
    if inp.rolling_e1rm_trend > 0:
        trend_bonus = min(inp.rolling_e1rm_trend * 0.1, max_weight_increment * 0.5)

    # Project weight for target reps at new 1RM
    projected_weight = epley_weight(current_e1rm, target_reps)
    raw_increment = projected_weight - inp.current_weight

    # Clamp increment
    weight_increment = min(raw_increment, max_weight_increment + trend_bonus)
    weight_increment = max(weight_increment, 0)

    if weight_increment >= inp.weight_increment:
        # Weight increase
        new_weight = round_to_increment(inp.current_weight + weight_increment, inp.weight_increment)
        # Reset reps to base when weight goes up
        new_reps = target_reps if target_reps else max(inp.current_reps - 2, 5)
        new_e1rm = epley_1rm(new_weight, new_reps)

        confidence = "high" if strength_gain > noise_threshold * 2 else "medium"
        return OverloadResult(
            next_weight=new_weight,
            next_reps=new_reps,
            strategy="weight_up",
            confidence=confidence,
            explanation=f"Increase weight {inp.current_weight:.0f} → {new_weight:.0f} ({weight_increment:.0f} lbs). Target {new_reps} reps.",
            estimated_1rm=current_e1rm,
            projected_1rm=new_e1rm,
        )
    else:
        # Increment too small for weight — add reps
        reps_increment = min(
            int((projected_weight - inp.current_weight) / inp.current_weight * 30),
            max_reps_increment
        )
        reps_increment = max(reps_increment, 1)
        new_reps = inp.current_reps + reps_increment
        new_e1rm = epley_1rm(inp.current_weight, new_reps)

        return OverloadResult(
            next_weight=inp.current_weight,
            next_reps=new_reps,
            strategy="reps_up",
            confidence="medium",
            explanation=f"Add {reps_increment} rep(s) ({inp.current_reps} → {new_reps}). Weight stays at {inp.current_weight:.0f}.",
            estimated_1rm=current_e1rm,
            projected_1rm=new_e1rm,
        )


# ── Helpers ──────────────────────────────────────────────────────────────

def epley_1rm(weight: float, reps: int) -> float:
    """Estimate 1RM using Epley formula."""
    if reps <= 0 or weight <= 0:
        return 0
    if reps == 1:
        return weight
    return weight * (1 + reps / 30)


def epley_weight(one_rm: float, reps: int) -> float:
    """Calculate weight for given reps at a 1RM."""
    if reps <= 0 or one_rm <= 0:
        return 0
    if reps == 1:
        return one_rm
    return one_rm / (1 + reps / 30)


def round_to_increment(weight: float, increment: float) -> float:
    """Round weight to nearest increment (e.g., nearest 5 lbs)."""
    return round(weight / increment) * increment


def _max_increment(exercise_type: str, training_level: str, base_increment: float) -> float:
    """Max weight increment per session by type and level."""
    multipliers = {
        ("compound", "beginner"): 4,      # 20 lbs
        ("compound", "intermediate"): 2,   # 10 lbs
        ("compound", "advanced"): 1,       # 5 lbs
        ("isolation", "beginner"): 2,      # 10 lbs
        ("isolation", "intermediate"): 1,  # 5 lbs
        ("isolation", "advanced"): 1,      # 5 lbs
    }
    mult = multipliers.get((exercise_type, training_level), 1)
    return base_increment * mult


def _max_reps_increment(exercise_type: str) -> int:
    """Max reps increment per session."""
    return 3 if exercise_type == "compound" else 2
