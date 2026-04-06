"""Helpers for persisted plan-level RIR overrides."""

from __future__ import annotations

from typing import Any


def _normalize_rir_value(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        rir = int(value)
    except (TypeError, ValueError):
        return None
    if 0 <= rir <= 5:
        return rir
    return None


def normalize_rir_overrides(raw: Any) -> dict:
    """Return a stable override shape from untrusted JSON data."""
    if not isinstance(raw, dict):
        raw = {}

    muscles_raw = raw.get("muscles")
    exercises_raw = raw.get("exercises")

    muscles: dict[str, int] = {}
    if isinstance(muscles_raw, dict):
        for key, value in muscles_raw.items():
            rir = _normalize_rir_value(value)
            if key and rir is not None:
                muscles[str(key)] = rir

    exercises: dict[str, int] = {}
    if isinstance(exercises_raw, dict):
        for key, value in exercises_raw.items():
            rir = _normalize_rir_value(value)
            if key and rir is not None:
                exercises[str(key)] = rir

    return {
        "plan": _normalize_rir_value(raw.get("plan")),
        "muscles": muscles,
        "exercises": exercises,
    }


def resolve_rir_override(planned_data: dict, exercise_id: int, primary_muscles: list[str] | None = None) -> int | None:
    """Resolve override precedence: exercise > muscle group > whole plan."""
    overrides = normalize_rir_overrides(planned_data.get("rir_overrides"))
    exercise_override = overrides["exercises"].get(str(exercise_id))
    if exercise_override is not None:
        return exercise_override

    if primary_muscles:
        for muscle in primary_muscles:
            muscle_override = overrides["muscles"].get(muscle)
            if muscle_override is not None:
                return muscle_override

    return overrides["plan"]
