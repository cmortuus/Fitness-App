"""Shared utilities for food database seeding scripts."""
import argparse
import json
import os
import sys

from sqlalchemy import create_engine, select, text
from sqlalchemy.orm import Session, sessionmaker

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from app.models.nutrition import FoodItem


def get_engine():
    url = os.environ.get("DATABASE_SYNC_URL", "sqlite:///./homegym.db")
    return create_engine(url, echo=False)


def get_session_factory(engine=None):
    if engine is None:
        engine = get_engine()
    return sessionmaker(bind=engine)


def base_argparser(description: str) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--dry-run", action="store_true", help="Parse and validate but don't insert")
    p.add_argument("--batch-size", type=int, default=500, help="Rows per commit batch")
    p.add_argument("--limit", type=int, default=0, help="Max rows to process (0 = unlimited)")
    p.add_argument("--verbose", "-v", action="store_true", help="Print every rejected row")
    return p


def validate_food(data: dict, verbose: bool = False) -> bool:
    """Reject foods with implausible or missing data."""
    name = (data.get("name") or "").strip()
    if not name:
        if verbose:
            print(f"  SKIP: empty name")
        return False

    cal = data.get("calories_per_100g")
    pro = data.get("protein_per_100g")
    carb = data.get("carbs_per_100g")
    fat = data.get("fat_per_100g")

    # Must have at least calories
    if cal is None:
        if verbose:
            print(f"  SKIP: no calories — {name}")
        return False

    # Reject negative values
    for val, label in [(cal, "cal"), (pro, "protein"), (carb, "carbs"), (fat, "fat")]:
        if val is not None and val < 0:
            if verbose:
                print(f"  SKIP: negative {label} — {name}")
            return False

    # Reject implausible calories (pure fat is ~900 kcal/100g, allow some margin)
    if cal > 1000:
        if verbose:
            print(f"  SKIP: cal={cal} > 1000 — {name}")
        return False

    return True


def batch_insert_foods(
    session_factory,
    foods: list[dict],
    batch_size: int = 500,
    dry_run: bool = False,
    verbose: bool = False,
) -> dict:
    """Insert foods in batches, skipping existing barcodes. Returns stats."""
    stats = {"inserted": 0, "skipped_existing": 0, "skipped_invalid": 0, "total": len(foods)}

    for i in range(0, len(foods), batch_size):
        batch = foods[i : i + batch_size]

        if dry_run:
            for f in batch:
                if validate_food(f, verbose):
                    stats["inserted"] += 1
                else:
                    stats["skipped_invalid"] += 1
            continue

        with session_factory() as session:
            # Check which barcodes already exist
            barcodes = [f["barcode"] for f in batch if f.get("barcode")]
            existing = set()
            if barcodes:
                result = session.execute(
                    select(FoodItem.barcode).where(FoodItem.barcode.in_(barcodes))
                )
                existing = {r[0] for r in result}

            # Also check source+source_id for barcode-less items
            source_ids = [(f["source"], f["source_id"]) for f in batch if f.get("source_id") and not f.get("barcode")]
            existing_source_ids = set()
            if source_ids:
                for src, sid in source_ids:
                    result = session.execute(
                        select(FoodItem.id).where(FoodItem.source == src, FoodItem.source_id == sid).limit(1)
                    )
                    if result.scalar_one_or_none():
                        existing_source_ids.add((src, sid))

            for f in batch:
                if not validate_food(f, verbose):
                    stats["skipped_invalid"] += 1
                    continue

                if f.get("barcode") and f["barcode"] in existing:
                    stats["skipped_existing"] += 1
                    continue

                if not f.get("barcode") and f.get("source_id"):
                    if (f["source"], f["source_id"]) in existing_source_ids:
                        stats["skipped_existing"] += 1
                        continue

                micros = f.get("micronutrients")
                item = FoodItem(
                    name=f["name"][:200],
                    brand=(f.get("brand") or "")[:200] or None,
                    barcode=(f.get("barcode") or "")[:50] or None,
                    source=f.get("source", "community"),
                    source_id=(f.get("source_id") or "")[:100] or None,
                    calories_per_100g=f.get("calories_per_100g"),
                    protein_per_100g=f.get("protein_per_100g"),
                    carbs_per_100g=f.get("carbs_per_100g"),
                    fat_per_100g=f.get("fat_per_100g"),
                    serving_size_g=f.get("serving_size_g", 100.0),
                    serving_label=(f.get("serving_label") or "")[:100] or None,
                    micronutrients=json.dumps(micros) if micros else None,
                    is_custom=False,
                    user_id=None,
                )
                session.add(item)
                stats["inserted"] += 1

            session.commit()

        processed = i + len(batch)
        print(f"  Batch {i // batch_size + 1}: {processed}/{stats['total']} processed, {stats['inserted']} inserted")

    return stats
