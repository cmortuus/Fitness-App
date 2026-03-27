#!/usr/bin/env python3
"""Import foods from Open Food Facts CSV/TSV dump.

Downloads the gzipped TSV from Open Food Facts and stream-parses it.
Run:
    python scripts/seed_food_db/import_openfoodfacts.py --limit 1000 --dry-run
    python scripts/seed_food_db/import_openfoodfacts.py  # full import
"""
import csv
import gzip
import os
import sys
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from scripts.seed_food_db.common import base_argparser, batch_insert_foods, get_session_factory, validate_food

DUMP_URL = "https://static.openfoodfacts.org/data/en.openfoodfacts.org.products.csv.gz"
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "food_dumps")
LOCAL_FILE = os.path.join(DATA_DIR, "openfoodfacts.csv.gz")

# OFF TSV column names → our field mapping
OFF_MICROS = {
    "fiber_100g": "fiber_g",
    "sugars_100g": "sugar_g",
    "sodium_100g": "sodium_mg",
    "calcium_100g": "calcium_mg",
    "iron_100g": "iron_mg",
    "magnesium_100g": "magnesium_mg",
    "potassium_100g": "potassium_mg",
    "zinc_100g": "zinc_mg",
    "phosphorus_100g": "phosphorus_mg",
    "vitamin-a_100g": "vitamin_a_mcg",
    "vitamin-c_100g": "vitamin_c_mg",
    "vitamin-d_100g": "vitamin_d_mcg",
    "vitamin-e_100g": "vitamin_e_mg",
    "vitamin-b12_100g": "vitamin_b12_mcg",
    "cholesterol_100g": "cholesterol_mg",
}


def _safe_float(val: str) -> float | None:
    if not val or val.strip() == "":
        return None
    try:
        v = float(val)
        return v if v >= 0 else None
    except (ValueError, TypeError):
        return None


def _parse_serving_size(val: str) -> float:
    if not val:
        return 100.0
    import re
    m = re.search(r"(\d+\.?\d*)\s*g", val, re.IGNORECASE)
    return float(m.group(1)) if m else 100.0


def normalize_off_row(row: dict) -> dict | None:
    """Normalize a TSV row from the OFF dump."""
    name = (row.get("product_name") or row.get("product_name_en") or "").strip()
    if not name:
        return None

    code = (row.get("code") or "").strip()
    brand = (row.get("brands") or "").split(",")[0].strip() or None

    cal = _safe_float(row.get("energy-kcal_100g") or row.get("energy_100g", ""))
    protein = _safe_float(row.get("proteins_100g", ""))
    carbs = _safe_float(row.get("carbohydrates_100g", ""))
    fat = _safe_float(row.get("fat_100g", ""))

    micros = {}
    for off_key, our_key in OFF_MICROS.items():
        val = _safe_float(row.get(off_key, ""))
        if val is not None and val > 0:
            micros[our_key] = round(val, 3)

    return {
        "name": name,
        "brand": brand,
        "source": "openfoodfacts",
        "source_id": code or None,
        "barcode": code or None,
        "calories_per_100g": cal,
        "protein_per_100g": protein,
        "carbs_per_100g": carbs,
        "fat_per_100g": fat,
        "serving_size_g": _parse_serving_size(row.get("serving_size", "")),
        "serving_label": (row.get("serving_size") or "")[:100] or None,
        "micronutrients": micros or None,
    }


def download_dump():
    os.makedirs(DATA_DIR, exist_ok=True)
    if os.path.exists(LOCAL_FILE):
        size_mb = os.path.getsize(LOCAL_FILE) / (1024 * 1024)
        print(f"Using cached dump: {LOCAL_FILE} ({size_mb:.0f} MB)")
        return

    print(f"Downloading OFF dump from {DUMP_URL}...")
    print("This may take a while (~2 GB compressed)...")
    urllib.request.urlretrieve(DUMP_URL, LOCAL_FILE)
    size_mb = os.path.getsize(LOCAL_FILE) / (1024 * 1024)
    print(f"Downloaded: {size_mb:.0f} MB")


GENERIC_KEYWORDS = {
    "chicken", "beef", "pork", "turkey", "salmon", "tuna", "shrimp", "cod", "tilapia",
    "rice", "pasta", "oats", "flour", "sugar", "salt", "oil", "butter", "milk", "cream",
    "egg", "banana", "apple", "orange", "potato", "tomato", "onion", "garlic", "carrot",
    "broccoli", "spinach", "lettuce", "avocado", "lemon", "lime",
}


def _is_generic(name: str) -> bool:
    """Check if a food name looks like a generic/raw ingredient rather than a branded product."""
    words = set(name.lower().split())
    return bool(words & GENERIC_KEYWORDS) and len(name.split()) <= 4


def stream_foods(limit: int = 0, verbose: bool = False):
    """Stream-parse the gzipped TSV and yield normalized food dicts.

    Deduplicates by barcode within the stream. For generic/raw foods
    (e.g., chicken breast, rice), keeps only the first entry per
    normalized name to avoid dozens of near-identical entries.
    """
    count = 0
    skipped = 0
    seen_barcodes: set[str] = set()
    seen_generic_names: set[str] = set()

    with gzip.open(LOCAL_FILE, "rt", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            food = normalize_off_row(row)
            if food is None:
                skipped += 1
                continue
            if not validate_food(food, verbose):
                skipped += 1
                continue

            bc = food.get("barcode")
            if bc:
                if bc in seen_barcodes:
                    skipped += 1
                    continue
                seen_barcodes.add(bc)

            name = food.get("name", "")
            if _is_generic(name):
                norm_name = name.lower().strip()
                if norm_name in seen_generic_names:
                    skipped += 1
                    continue
                seen_generic_names.add(norm_name)

            yield food
            count += 1
            if limit and count >= limit:
                break
            if count % 100_000 == 0:
                print(f"  Parsed {count:,} foods ({skipped:,} skipped)...")

    print(f"Parsed {count:,} valid foods, {skipped:,} skipped")
    print(f"  Dedup: {len(seen_barcodes):,} unique barcodes, {len(seen_generic_names):,} generic names kept")


def main():
    parser = base_argparser("Import foods from Open Food Facts TSV dump")
    parser.add_argument("--skip-download", action="store_true", help="Use existing cached dump")
    args = parser.parse_args()

    if not args.skip_download:
        download_dump()
    elif not os.path.exists(LOCAL_FILE):
        print(f"No cached dump at {LOCAL_FILE}. Run without --skip-download first.")
        sys.exit(1)

    print("Streaming and collecting foods...")
    foods = list(stream_foods(limit=args.limit, verbose=args.verbose))
    print(f"Collected {len(foods):,} foods for insertion")

    if not foods:
        print("No foods to insert.")
        return

    factory = get_session_factory()
    stats = batch_insert_foods(factory, foods, batch_size=args.batch_size, dry_run=args.dry_run, verbose=args.verbose)

    print(f"\nDone! Inserted: {stats['inserted']:,}, Skipped (existing): {stats['skipped_existing']:,}, Skipped (invalid): {stats['skipped_invalid']:,}")
    if args.dry_run:
        print("[DRY RUN — no data was written]")


if __name__ == "__main__":
    main()
