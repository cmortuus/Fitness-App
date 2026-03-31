"""Progressive overload calculation helpers.

These are pure (stateless) functions extracted from create_session_from_plan
so they can be tested and reused independently.
"""

from __future__ import annotations


def rep_bracket(reps: int) -> int:
    """Map a rep count to a bracket tier (1, 2, or 3).

    Brackets:
      1 → 1–9 reps
      2 → 10–14 reps
      3 → 15+ reps

    A weight increase is triggered when the projected rep count would
    cross into a higher bracket.
    """
    if reps >= 15:
        return 3
    if reps >= 10:
        return 2
    return 1


def _bracket_floor(bracket: int) -> int:
    """Return the lowest rep count in a bracket (for resetting after weight-up)."""
    if bracket >= 3:
        return 15
    if bracket == 2:
        return 10
    return 5  # don't go below 5 for bracket 1


def epley_weight_for_reps(weight: float, done_reps: int, target_reps: int) -> float:
    """Estimate the weight needed to achieve *target_reps* given that
    *weight* was lifted for *done_reps*, using the Epley 1RM formula.

    Result is rounded to the nearest 2.5 kg (~5 lb plate increment).
    """
    # Guard: Epley is invalid for non-positive reps or dangerous target values
    if done_reps <= 0:
        done_reps = 1
    if target_reps <= 0:
        target_reps = 1
    one_rm = weight * (1 + done_reps / 30)
    new_w = one_rm / (1 + target_reps / 30)
    return round(new_w / 2.5) * 2.5


def adjust_load_for_target_rir(
    prior_weight: float | None,
    prior_reps: int | None,
    target_reps: int,
    target_rir: int | None,
    *,
    is_assisted: bool = False,
    body_weight_kg: float = 0.0,
) -> float | None:
    """Return an easier next-session load for the same target reps at the requested RIR."""
    if (
        target_rir is None
        or target_rir <= 0
        or prior_weight is None
        or prior_weight <= 0
        or prior_reps is None
        or prior_reps <= 0
        or target_reps <= 0
    ):
        return prior_weight

    if is_assisted:
        if body_weight_kg <= 0:
            return prior_weight
        prior_net = body_weight_kg - prior_weight
        if prior_net <= 0:
            return prior_weight
        easier_net = epley_weight_for_reps(prior_net, prior_reps, target_reps + target_rir)
        return max(0.0, round((body_weight_kg - easier_net) / 2.5) * 2.5)

    return epley_weight_for_reps(prior_weight, prior_reps, target_reps + target_rir)


def compute_overload(
    *,
    prior_weight: float,
    prior_reps: int,
    planned_reps: int,
    overload_style: str = "rep",
    is_assisted: bool = False,
    is_bodyweight: bool = False,
    body_weight_kg: float = 0.0,
) -> tuple[float | None, int | None]:
    """Return ``(suggested_weight_kg, suggested_reps)`` for the next session.

    Args:
        prior_weight:   Actual weight used in the previous session's set.
                        For assisted exercises this is the *assist amount*
                        (positive kg).  "Progress" means reducing the assist.
        prior_reps:     Actual reps completed in the previous session's set.
        planned_reps:   The target rep count from the programme.
        overload_style: ``"rep"`` (default) — add a rep first, reduce assist
                        at bracket boundary.  ``"weight"`` — immediately reduce
                        assist by one rep's worth via Epley on the net load.
        is_assisted:    True for exercises where the machine *reduces* the load
                        (e.g. assisted pull-up/dip).  prior_weight is the assist
                        amount; returned weight is a new (lower) assist amount.
        is_bodyweight:  True for pure bodyweight moves (weight == 0 / not tracked).
        body_weight_kg: User body weight, used for Epley on net load when
                        overload_style="weight" and is_assisted=True.

    Returns:
        A ``(weight, reps)`` tuple.  Either component may be ``None`` when
        there is no meaningful suggestion (e.g. first session, bodyweight with
        no weight tracked).
    """
    if prior_reps is None or prior_reps <= 0:
        return None, None
    if prior_weight is None:
        return None, None

    # ── Assisted exercises ─────────────────────────────────────────────────
    # prior_weight = assist amount (positive).  Progress = less assist.
    if is_assisted:
        if prior_reps < planned_reps:
            # Didn't hit target — retry same assist, re-attempt planned target
            return prior_weight, planned_reps

        # Hit target — apply progression
        if overload_style == "weight" and body_weight_kg > 0 and prior_weight > 0:
            # Use Epley on the net load to find the equivalent harder net,
            # then convert back to assist amount.
            prior_net = body_weight_kg - prior_weight
            new_net = epley_weight_for_reps(prior_net, prior_reps + 1, prior_reps)
            new_assist = max(0.0, round((body_weight_kg - new_net) / 2.5) * 2.5)
            return new_assist, prior_reps

        # Rep-style (default): add a rep; reduce assist at bracket boundary
        projected = prior_reps + 1
        if rep_bracket(projected) <= rep_bracket(prior_reps):
            return prior_weight, projected          # same assist, more reps
        else:
            # Bracket boundary — reduce assist by 2.5 kg (≈5 lbs) and hold reps
            new_assist = max(0.0, round((prior_weight - 2.5) / 2.5) * 2.5)
            return new_assist, prior_reps

    # ── Pure bodyweight ────────────────────────────────────────────────────
    if is_bodyweight:
        if prior_reps >= planned_reps:
            return None, prior_reps + 1
        return None, prior_reps

    # ── Weighted exercises ─────────────────────────────────────────────────

    # Minimum rep floor: never plan fewer than 4 reps.
    # If the user got fewer than 4 reps, reduce weight (via Epley) to a load
    # where they should be able to get 4 reps rather than planning an
    # unproductive sub-4-rep set at the same load.
    MIN_REPS = 4
    if prior_reps < MIN_REPS and prior_weight > 0:
        weight_for_min = epley_weight_for_reps(prior_weight, prior_reps, MIN_REPS)
        return weight_for_min, MIN_REPS

    # Didn't hit planned reps (but ≥ floor) → retry same weight, re-attempt planned target
    if prior_reps < planned_reps:
        return prior_weight, planned_reps

    # Hit target: apply progression
    if overload_style == "weight":
        new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
        return new_weight, prior_reps
    else:
        projected_reps = prior_reps + 1
        if rep_bracket(projected_reps) <= rep_bracket(prior_reps):
            return prior_weight, projected_reps
        else:
            # Bracket boundary crossed — increase weight, reset reps to bracket floor
            new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
            # Ensure at least one minimum increment (2.5 kg) when crossing a bracket
            if new_weight <= prior_weight:
                new_weight = round((prior_weight + 2.5) / 2.5) * 2.5
            # Reset reps to bottom of current bracket (e.g., 14→10 for bracket 2)
            reset_reps = _bracket_floor(rep_bracket(prior_reps))
            return new_weight, reset_reps
