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


def epley_weight_for_reps(weight: float, done_reps: int, target_reps: int) -> float:
    """Estimate the weight needed to achieve *target_reps* given that
    *weight* was lifted for *done_reps*, using the Epley 1RM formula.

    Result is rounded to the nearest 2.5 kg (~5 lb plate increment).
    """
    one_rm = weight * (1 + done_reps / 30)
    new_w = one_rm / (1 + target_reps / 30)
    return round(new_w / 2.5) * 2.5


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
                        For assisted exercises this is the *net* load
                        (body_weight − assist_amount).
        prior_reps:     Actual reps completed in the previous session's set.
        planned_reps:   The target rep count from the programme.
        overload_style: ``"rep"`` (default) — add a rep first, bump weight
                        at bracket boundary.  ``"weight"`` — immediately
                        convert the extra rep into equivalent weight via Epley.
        is_assisted:    True for exercises where the machine *reduces* the load
                        (e.g. assisted pull-up/dip).  The returned weight is
                        the *assist amount* (not the net load) so the frontend
                        can pre-fill directly.
        is_bodyweight:  True for pure bodyweight moves (weight == 0 / not tracked).
        body_weight_kg: Required when *is_assisted* is True to back-calculate
                        the assist amount.

    Returns:
        A ``(weight, reps)`` tuple.  Either component may be ``None`` when
        there is no meaningful suggestion (e.g. first session, bodyweight with
        no weight tracked).
    """
    if prior_reps <= 0:
        return None, None

    # ── Assisted exercises ─────────────────────────────────────────────────
    if is_assisted:
        new_reps = prior_reps + 1 if prior_reps >= planned_reps else prior_reps
        if body_weight_kg > 0 and prior_weight > 0:
            # prior_weight is the net load; convert back to assist amount
            assist_kg = max(0.0, round((body_weight_kg - prior_weight) / 1.25) * 1.25)
            return assist_kg, new_reps
        return None, new_reps

    # ── Pure bodyweight ────────────────────────────────────────────────────
    if is_bodyweight:
        if prior_reps >= planned_reps:
            return None, prior_reps + 1
        return None, prior_reps

    # ── Weighted exercises ─────────────────────────────────────────────────

    # Didn't hit planned reps → retry same weight / same reps
    if prior_reps < planned_reps:
        return prior_weight, prior_reps

    # Hit target: apply progression
    if overload_style == "weight":
        new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
        return new_weight, prior_reps
    else:
        projected_reps = prior_reps + 1
        if rep_bracket(projected_reps) <= rep_bracket(prior_reps):
            return prior_weight, projected_reps
        else:
            new_weight = epley_weight_for_reps(prior_weight, prior_reps + 1, prior_reps)
            return new_weight, prior_reps
