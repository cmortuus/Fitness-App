#!/usr/bin/env python3
"""Seed 500+ exercises."""
import asyncio

from app.database import async_session_factory, init_db
from app.models.exercise import Exercise

# Equipment type mapping by name prefix
EQUIPMENT_MAP = {
    "barbell": "barbell",
    "db": "dumbbell",
    "smith": "plate_loaded",
    "cable": "cable",
    "kb": "kettlebell",
    "bodyweight": "bodyweight",
    "body": "bodyweight",
    "machine": "machine",
    "band": "band",
    "tbar": "plate_loaded",
    "weighted": "bodyweight",  # weighted pullups/dips are still bodyweight category
    "assist": "machine",       # assisted pullups/dips use a machine
    "press": "machine",        # calf press machines
    "ring": "bodyweight",
    "parallel": "bodyweight",  # parallel dips
    "bench": "bodyweight",     # bench dips
}


def get_equipment_type(name: str) -> str:
    """Determine equipment type from exercise name prefix."""
    prefix = name.split("_")[0]
    return EQUIPMENT_MAP.get(prefix, "other")


def generate_all_exercises():
    ex = []

    # SQUAT 80
    si = ["barbell", "db", "smith", "cable", "kb", "bodyweight", "machine", "band"]
    ss = ["back", "front", "sumo", "box", "pause", "tempo", "deficit", "overhead", "zercher", "safety_bar"]
    for i in si:
        for s in ss:
            ex.append({"name": f"{i}_{s}_squat", "display": f"{i.title()} {s.title()} Squat", "type": "squat", "primary": ["quads", "glutes"], "secondary": ["hamstrings", "core"]})

    # HINGE 48
    hi = ["barbell", "db", "smith", "cable", "kb", "bodyweight"]
    hs = ["conventional", "sumo", "romanian", "stiff", "trap", "deficit", "block", "snatch"]
    for i in hi:
        for s in hs:
            ex.append({"name": f"{i}_{s}_dl", "display": f"{i.title()} {s.title()} DL", "type": "hinge", "primary": ["hamstrings", "glutes", "back"], "secondary": ["traps", "core"]})

    # LUNGE 42
    li = ["barbell", "db", "kb", "body", "smith", "cable"]
    ls = ["walking", "reverse", "lateral", "curtsy", "jump", "bulgarian", "split"]
    for i in li:
        for s in ls:
            ex.append({"name": f"{i}_{s}_lunge", "display": f"{i.title()} {s.title()} Lunge", "type": "lunge", "primary": ["quads", "glutes"], "secondary": ["hamstrings", "calves"]})

    # BENCH 36
    bi = ["barbell", "db", "smith", "cable", "machine", "body"]
    ba = ["flat", "incline", "decline", "floor", "pushup", "dip"]
    for i in bi:
        for a in ba:
            ex.append({"name": f"{i}_{a}", "display": f"{i.title()} {a.title()}", "type": "compound", "primary": ["chest", "triceps"], "secondary": ["shoulders"]})

    # OHP 30
    oi = ["barbell", "db", "smith", "cable", "machine", "kb"]
    os = ["strict", "push", "jerk", "arnold", "landmine"]
    for i in oi:
        for s in os:
            ex.append({"name": f"{i}_{s}_press", "display": f"{i.title()} {s.title()} Press", "type": "compound", "primary": ["shoulders", "triceps"], "secondary": ["upper_chest"]})

    # ROW 54
    ri = ["barbell", "db", "cable", "machine", "body", "tbar"]
    rs = ["bent", "seal", "chest"]
    rg = ["prone", "supine", "neutral"]
    for i in ri:
        for s in rs:
            for g in rg:
                ex.append({"name": f"{i}_{s}_{g}_row", "display": f"{i.title()} {s.title()} {g.title()} Row", "type": "compound", "primary": ["lats", "rhomboids", "traps"], "secondary": ["rear_delts", "biceps"]})

    # PULLUP 30
    pi = ["body", "weighted", "assist", "band", "machine"]
    pg = ["prone", "supine", "neutral", "wide", "close", "reverse"]
    for i in pi:
        for g in pg:
            ex.append({"name": f"{i}_{g}_pull", "display": f"{i.title()} {g.title()} Pull", "type": "compound", "primary": ["lats", "rhomboids"], "secondary": ["biceps"]})

    # DIP 10
    ds = ["parallel", "bench", "ring", "assist", "weighted"]
    dt = ["chest", "tricep"]
    for s in ds:
        for t in dt:
            ex.append({"name": f"{s}_{t}_dip", "display": f"{s.title()} {t.title()} Dip", "type": "compound", "primary": ["triceps", "chest"], "secondary": ["shoulders"]})

    # CORE 20
    core = ["crunch", "situp", "leg_raise", "plank", "rollout", "deadbug", "birddog", "pallof", "chop", "lift", "twist", "side_plank", "carry", "vacuum", "knee_raise", "toes_bar", "dragon", "hollow", "arch", "superman"]
    for c in core:
        ex.append({"name": c, "display": c.replace("_", " ").title(), "type": "isolation", "primary": ["abs", "obliques"], "secondary": ["hip_flexors"]})

    # CALF 15
    ci = ["body", "db", "smith", "machine", "press"]
    cs = ["stand", "sit", "donkey"]
    for i in ci:
        for s in cs:
            ex.append({"name": f"{i}_{s}_calf", "display": f"{i.title()} {s.title()} Calf", "type": "isolation", "primary": ["gastrocnemius", "soleus"], "secondary": ["tibialis"]})

    return ex

async def seed():
    await init_db()
    inserted = 0
    updated = 0
    async with async_session_factory() as session:
        from sqlalchemy import select
        for ed in generate_all_exercises():
            result = await session.execute(select(Exercise).where(Exercise.name == ed["name"]))
            existing = result.scalar_one_or_none()
            eq_type = get_equipment_type(ed["name"])
            if existing:
                # Update equipment_type if it was left as default "other"
                if existing.equipment_type in (None, "other", "") and eq_type != "other":
                    existing.equipment_type = eq_type
                    updated += 1
                continue
            ex = Exercise(
                name=ed["name"],
                display_name=ed["display"],
                movement_type=ed["type"],
                equipment_type=eq_type,
                primary_muscles=ed.get("primary", []),
                secondary_muscles=ed.get("secondary", []),
            )
            session.add(ex)
            inserted += 1
        await session.commit()
    print(f"Seeded {inserted} new exercises, updated {updated} equipment types")

if __name__ == "__main__":
    asyncio.run(seed())
