#!/usr/bin/env python3
"""Import foods from USDA FoodData Central branded foods JSON download.

Downloads the branded foods JSON from USDA and stream-parses with ijson.
Run:
    python scripts/seed_food_db/import_usda.py --limit 1000 --dry-run
    python scripts/seed_food_db/import_usda.py  # full import
"""
import json
import os
import sys
import urllib.request
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from scripts.seed_food_db.common import base_argparser, batch_insert_foods, get_session_factory, validate_food

DOWNLOAD_URL = "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_branded_food_json_2024-10-01.zip"
DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "food_dumps")
ZIP_FILE = os.path.join(DATA_DIR, "usda_branded.zip")
JSON_FILE = os.path.join(DATA_DIR, "usda_branded.json")

# USDA nutrient IDs
USDA_CALORIES = 1008
USDA_PROTEIN = 1003
USDA_CARBS = 1005
USDA_FAT = 1004
USDA_MICROS = {
    1079: "fiber_g",
    2000: "sugar_g",
    1093: "sodium_mg",
    1087: "calcium_mg",
    1089: "iron_mg",
    1090: "magnesium_mg",
    1092: "potassium_mg",
    1095: "zinc_mg",
    1091: "phosphorus_mg",
    1106: "vitamin_a_mcg",
    1162: "vitamin_c_mg",
    1114: "vitamin_d_mcg",
    1109: "vitamin_e_mg",
    1178: "vitamin_b12_mcg",
    1253: "cholesterol_mg",
}


def normalize_usda_food(food: dict) -> dict | None:
    name = food.get("description")
    if not name:
        return None

    nutrients = {}
    for n in food.get("foodNutrients", []):
        nid = n.get("nutrient", {}).get("id") or n.get("nutrientId")
        val = n.get("amount") or n.get("value")
        if nid and val is not None:
            nutrients[nid] = val

    micros = {}
    for usda_id, our_key in USDA_MICROS.items():
        val = nutrients.get(usda_id)
        if val is not None and val > 0:
            micros[our_key] = round(val, 3)

    return {
        "name": name,
        "brand": food.get("brandName") or food.get("brandOwner"),
        "source": "usda",
        "source_id": str(food.get("fdcId", "")),
        "barcode": food.get("gtinUpc"),
        "calories_per_100g": nutrients.get(USDA_CALORIES),
        "protein_per_100g": nutrients.get(USDA_PROTEIN),
        "carbs_per_100g": nutrients.get(USDA_CARBS),
        "fat_per_100g": nutrients.get(USDA_FAT),
        "serving_size_g": 100.0,
        "serving_label": None,
        "micronutrients": micros or None,
    }


def download_dump():
    os.makedirs(DATA_DIR, exist_ok=True)
    if os.path.exists(JSON_FILE):
        size_mb = os.path.getsize(JSON_FILE) / (1024 * 1024)
        print(f"Using cached USDA JSON: {JSON_FILE} ({size_mb:.0f} MB)")
        return

    if not os.path.exists(ZIP_FILE):
        print(f"Downloading USDA branded foods from {DOWNLOAD_URL}...")
        print("This may take a while (~300 MB)...")
        urllib.request.urlretrieve(DOWNLOAD_URL, ZIP_FILE)
        size_mb = os.path.getsize(ZIP_FILE) / (1024 * 1024)
        print(f"Downloaded: {size_mb:.0f} MB")

    print("Extracting ZIP...")
    with zipfile.ZipFile(ZIP_FILE, "r") as zf:
        json_names = [n for n in zf.namelist() if n.endswith(".json")]
        if not json_names:
            print("No JSON file found in ZIP!")
            sys.exit(1)
        # Extract the largest JSON file (the main data file)
        json_name = max(json_names, key=lambda n: zf.getinfo(n).file_size)
        print(f"Extracting {json_name}...")
        with zf.open(json_name) as src, open(JSON_FILE, "wb") as dst:
            import shutil
            shutil.copyfileobj(src, dst)

    size_mb = os.path.getsize(JSON_FILE) / (1024 * 1024)
    print(f"Extracted: {size_mb:.0f} MB")


def stream_foods(limit: int = 0, verbose: bool = False):
    """Stream-parse USDA JSON and yield normalized food dicts."""
    try:
        import ijson
    except ImportError:
        print("ijson not installed. Install with: pip install ijson")
        print("Falling back to full JSON load (uses more memory)...")
        yield from _fallback_load(limit, verbose)
        return

    count = 0
    skipped = 0
    with open(JSON_FILE, "rb") as f:
        # USDA JSON has foods under various keys depending on the file version
        # Try common structures: root array, "BrandedFoods", "SurveyFoods", or "FoundationFoods"
        for food in ijson.items(f, "BrandedFoods.item"):
            normalized = normalize_usda_food(food)
            if normalized is None or not validate_food(normalized, verbose):
                skipped += 1
                continue
            yield normalized
            count += 1
            if limit and count >= limit:
                break
            if count % 50_000 == 0:
                print(f"  Parsed {count:,} foods ({skipped:,} skipped)...")

    if count == 0:
        # Try root-level array
        print("  No foods found under 'BrandedFoods', trying root array...")
        with open(JSON_FILE, "rb") as f:
            for food in ijson.items(f, "item"):
                normalized = normalize_usda_food(food)
                if normalized is None or not validate_food(normalized, verbose):
                    skipped += 1
                    continue
                yield normalized
                count += 1
                if limit and count >= limit:
                    break
                if count % 50_000 == 0:
                    print(f"  Parsed {count:,} foods ({skipped:,} skipped)...")

    print(f"Parsed {count:,} valid foods, {skipped:,} skipped")


def _fallback_load(limit: int, verbose: bool):
    """Load entire JSON into memory (fallback if ijson unavailable)."""
    print("Loading full JSON into memory...")
    with open(JSON_FILE) as f:
        data = json.load(f)

    foods = data if isinstance(data, list) else data.get("BrandedFoods", data.get("Foods", []))
    count = 0
    for food in foods:
        normalized = normalize_usda_food(food)
        if normalized is None or not validate_food(normalized, verbose):
            continue
        yield normalized
        count += 1
        if limit and count >= limit:
            break


def main():
    parser = base_argparser("Import foods from USDA FoodData Central branded foods")
    parser.add_argument("--skip-download", action="store_true", help="Use existing cached dump")
    args = parser.parse_args()

    if not args.skip_download:
        download_dump()
    elif not os.path.exists(JSON_FILE):
        print(f"No cached JSON at {JSON_FILE}. Run without --skip-download first.")
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
