#!/usr/bin/env python3
"""Seed the database with a curated list of common everyday foods.

These are the "obvious" results users expect when they search for staples like
bread, burger, rice, chicken, etc.  Having them in the local DB ensures they
always appear at the top of search results even when the larger USDA/OFF
imports haven't been run.

Nutrition values are sourced from USDA FoodData Central SR Legacy data and
represent plain, unbranded versions of each food.

Usage:
    python scripts/seed_food_db/seed_common.py
    python scripts/seed_food_db/seed_common.py --dry-run
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from common import base_argparser, batch_insert_foods, get_session_factory  # noqa: E402

# fmt: off
# Each tuple: (name, cal/100g, protein/100g, carbs/100g, fat/100g, serving_g, serving_label, micros_dict)
_COMMON_FOODS = [
    # ── Bread & baked goods ───────────────────────────────────────────────────
    ("Bread, White",              265, 9.0, 49.0, 3.2,  28,  "1 slice (28g)",    {"fiber_g": 2.3, "sodium_mg": 491}),
    ("Bread, Whole Wheat",        247, 13.0, 41.0, 3.4,  28,  "1 slice (28g)",    {"fiber_g": 6.0, "sodium_mg": 400}),
    ("Bread, Sourdough",          259, 9.5, 51.0, 1.8,  28,  "1 slice (28g)",    {"fiber_g": 1.7, "sodium_mg": 460}),
    ("Bread, Rye",                259, 8.5, 48.0, 3.3,  28,  "1 slice (28g)",    {"fiber_g": 5.8, "sodium_mg": 560}),
    ("Bread, Multigrain",         251, 10.0, 43.0, 4.0,  28,  "1 slice (28g)",    {"fiber_g": 5.0, "sodium_mg": 380}),
    ("Bagel, Plain",              270, 10.0, 53.0, 1.5,  98,  "1 medium bagel",   {"fiber_g": 2.1, "sodium_mg": 439}),
    ("English Muffin",            223, 8.5, 41.0, 2.0,  57,  "1 muffin (57g)",   {"fiber_g": 2.0, "sodium_mg": 405}),
    ("Pita Bread",                275, 9.1, 55.7, 1.2,  60,  "1 pita (60g)",     {"fiber_g": 2.2, "sodium_mg": 536}),
    ("Tortilla, Flour",           303, 7.7, 50.3, 7.7,  45,  "1 medium (45g)",   {"fiber_g": 1.8, "sodium_mg": 541}),
    ("Tortilla, Corn",            222, 5.7, 46.5, 2.5,  26,  "1 tortilla (26g)", {"fiber_g": 4.1, "sodium_mg":  10}),
    ("Croissant",                 406, 8.2, 45.8, 21.0, 57,  "1 croissant",      {"fiber_g": 1.7, "sodium_mg": 400}),
    ("Breadcrumbs, Plain",        395, 13.4, 72.5, 5.3, 28,  "¼ cup (28g)",      {"fiber_g": 3.5, "sodium_mg": 791}),

    # ── Burger & beef ─────────────────────────────────────────────────────────
    ("Burger, Beef Patty (cooked)", 295, 26.0, 0.0, 20.3, 85,  "1 patty (85g)",  {"sodium_mg": 75,  "iron_mg": 2.4}),
    ("Burger, Turkey Patty (cooked)", 218, 27.4, 0.0, 12.0, 85, "1 patty (85g)", {"sodium_mg": 88}),
    ("Burger, Veggie Patty",       124, 11.0, 9.0,  4.5, 71,  "1 patty (71g)",   {"fiber_g": 3.4, "sodium_mg": 398}),
    ("Ground Beef, 80/20 (cooked)",275, 26.1, 0.0, 18.5, 85,  "3 oz cooked",     {"sodium_mg": 76,  "iron_mg": 2.2}),
    ("Ground Beef, 90/10 (cooked)",218, 28.0, 0.0, 11.1, 85,  "3 oz cooked",     {"sodium_mg": 77,  "iron_mg": 2.4}),
    ("Hamburger Bun",              279, 8.4, 50.5, 4.6,  43,  "1 bun (43g)",     {"fiber_g": 1.8, "sodium_mg": 406}),

    # ── Chicken ───────────────────────────────────────────────────────────────
    ("Chicken Breast, Cooked",     165, 31.0, 0.0,  3.6, 140, "1 breast (140g)", {"sodium_mg":  74, "potassium_mg": 440}),
    ("Chicken Breast, Raw",        114, 21.2, 0.0,  2.6, 100, "100g",            {"sodium_mg":  65}),
    ("Chicken Thigh, Cooked",      230, 26.0, 0.0, 14.0,  85, "3 oz cooked",     {"sodium_mg":  92}),
    ("Chicken Drumstick, Cooked",  216, 27.5, 0.0, 11.2,  85, "3 oz cooked",     {"sodium_mg":  86}),
    ("Chicken, Rotisserie (breast)",167, 30.9, 1.0,  4.5, 100, "100g",           {"sodium_mg": 340}),

    # ── Beef & pork ───────────────────────────────────────────────────────────
    ("Steak, Sirloin (cooked)",    207, 30.3, 0.0,  9.0,  85, "3 oz cooked",     {"iron_mg": 2.7, "sodium_mg": 56}),
    ("Steak, Ribeye (cooked)",     291, 24.0, 0.0, 21.0,  85, "3 oz cooked",     {"iron_mg": 2.0, "sodium_mg": 58}),
    ("Pork Chop, Cooked",          250, 27.0, 0.0, 15.0,  85, "3 oz cooked",     {"sodium_mg": 61}),
    ("Bacon, Cooked",              541, 37.0, 1.4, 42.0,  15, "2 slices (15g)",  {"sodium_mg": 1717}),
    ("Sausage, Pork (cooked)",     339, 19.0, 1.0, 28.5,  45, "1 link (45g)",    {"sodium_mg": 718}),

    # ── Fish & seafood ────────────────────────────────────────────────────────
    ("Salmon, Atlantic (cooked)",  206, 28.6, 0.0, 10.5,  85, "3 oz cooked",     {"omega3_g": 1.8, "sodium_mg": 59}),
    ("Tuna, Canned in Water",      116, 25.5, 0.0,  1.0,  85, "3 oz drained",    {"sodium_mg": 320}),
    ("Shrimp, Cooked",             99,  20.9, 0.0,  1.1,  85, "3 oz cooked",     {"sodium_mg": 190}),
    ("Tilapia, Cooked",            128, 26.2, 0.0,  2.6,  85, "3 oz cooked",     {"sodium_mg":  56}),
    ("Cod, Cooked",                105, 22.8, 0.0,  0.9,  85, "3 oz cooked",     {"sodium_mg":  77}),

    # ── Eggs & dairy ──────────────────────────────────────────────────────────
    ("Egg, Whole, Large",          143,  12.6, 0.7, 9.5,  50, "1 large egg",     {"cholesterol_mg": 373, "vitamin_d_mcg": 2.0}),
    ("Egg White",                   52,  10.9, 0.7, 0.2,  33, "1 large white",   {"sodium_mg": 166}),
    ("Milk, Whole",                 61,   3.2, 4.8, 3.3, 240, "1 cup (240ml)",   {"calcium_mg": 113, "vitamin_d_mcg": 1.3}),
    ("Milk, 2%",                    50,   3.4, 4.8, 2.0, 240, "1 cup (240ml)",   {"calcium_mg": 120}),
    ("Milk, Skim",                  34,   3.4, 5.0, 0.1, 240, "1 cup (240ml)",   {"calcium_mg": 125}),
    ("Greek Yogurt, Plain, 0% Fat", 59,  10.2, 3.8, 0.4, 170, "¾ cup (170g)",   {"calcium_mg": 111}),
    ("Greek Yogurt, Plain, 2% Fat", 73,   9.9, 5.0, 1.9, 170, "¾ cup (170g)",   {"calcium_mg": 100}),
    ("Yogurt, Plain, Whole Milk",   61,   3.5, 4.7, 3.3, 245, "1 cup (245g)",   {"calcium_mg": 296}),
    ("Cheddar Cheese",             402,  24.9, 1.3, 33.1,  28, "1 oz (28g)",     {"calcium_mg": 720, "sodium_mg": 621}),
    ("Mozzarella Cheese, Part Skim",254, 24.7, 2.8, 15.9,  28, "1 oz (28g)",    {"calcium_mg": 505, "sodium_mg": 466}),
    ("Cottage Cheese, 2% Fat",      90,  12.0, 4.3, 2.3, 226, "1 cup (226g)",   {"sodium_mg": 479}),
    ("Butter",                     717,   0.9, 0.1, 81.1,  14, "1 tbsp (14g)",   {"vitamin_a_mcg": 684}),

    # ── Grains & pasta ────────────────────────────────────────────────────────
    ("Rice, White, Cooked",        130,   2.7, 28.6, 0.3, 186, "1 cup cooked",   {"sodium_mg":   1}),
    ("Rice, Brown, Cooked",        111,   2.6, 23.0, 0.9, 195, "1 cup cooked",   {"fiber_g": 1.8, "sodium_mg": 5}),
    ("Pasta, Cooked",              158,   5.8, 30.9, 0.9, 140, "1 cup cooked",   {"fiber_g": 1.8, "sodium_mg": 1}),
    ("Pasta, Whole Wheat, Cooked", 174,   7.5, 37.2, 0.8, 140, "1 cup cooked",   {"fiber_g": 4.0, "sodium_mg": 4}),
    ("Oats, Rolled, Dry",          389,  16.9, 66.3, 6.9,  40, "½ cup dry (40g)",{"fiber_g": 10.6, "sodium_mg": 2}),
    ("Oatmeal, Cooked",             71,   2.5, 12.0, 1.5, 234, "1 cup cooked",   {"fiber_g": 2.0, "sodium_mg": 49}),
    ("Quinoa, Cooked",             120,   4.4, 21.3, 1.9, 185, "1 cup cooked",   {"fiber_g": 2.8, "sodium_mg": 13}),
    ("Flour, All-Purpose, White",  364,  10.3, 76.3, 1.0,  30, "¼ cup (30g)",    {"fiber_g": 2.7}),

    # ── Potatoes & vegetables ─────────────────────────────────────────────────
    ("Potato, Baked with Skin",     93,   2.5, 21.1, 0.1, 173, "1 medium (173g)",{"fiber_g": 2.3, "potassium_mg": 926}),
    ("Sweet Potato, Baked",         90,   2.0, 20.7, 0.1, 130, "1 medium (130g)",{"fiber_g": 3.3, "vitamin_a_mcg": 1403}),
    ("French Fries (fast food)",   274,   3.4, 36.0, 13.1,  85, "small serving", {"sodium_mg": 310, "fiber_g": 2.9}),
    ("Broccoli, Cooked",            35,   2.4,  7.2, 0.4,  78, "½ cup cooked",   {"fiber_g": 2.6, "vitamin_c_mg": 51}),
    ("Spinach, Cooked",             23,   3.0,  3.8, 0.3,  90, "½ cup cooked",   {"fiber_g": 2.2, "iron_mg": 3.6}),
    ("Broccoli, Raw",               34,   2.8,  6.6, 0.4, 100, "100g",           {"fiber_g": 2.6, "vitamin_c_mg": 89}),
    ("Carrot, Raw",                 41,   0.9,  9.6, 0.2, 100, "100g",           {"fiber_g": 2.8, "vitamin_a_mcg": 835}),
    ("Tomato, Raw",                 18,   0.9,  3.9, 0.2, 123, "1 medium",       {"fiber_g": 1.2, "vitamin_c_mg": 15}),

    # ── Fruits ────────────────────────────────────────────────────────────────
    ("Apple, Raw",                  52,   0.3, 13.8, 0.2, 182, "1 medium (182g)",{"fiber_g": 2.4, "vitamin_c_mg": 8}),
    ("Banana, Raw",                 89,   1.1, 22.8, 0.3, 118, "1 medium (118g)",{"fiber_g": 2.6, "potassium_mg": 422}),
    ("Orange, Raw",                 47,   0.9, 11.8, 0.1, 131, "1 medium (131g)",{"fiber_g": 2.4, "vitamin_c_mg": 70}),
    ("Blueberries, Raw",            57,   0.7, 14.5, 0.3, 148, "1 cup (148g)",   {"fiber_g": 2.4, "vitamin_c_mg": 14}),
    ("Strawberries, Raw",           32,   0.7,  7.7, 0.3, 152, "1 cup (152g)",   {"fiber_g": 2.0, "vitamin_c_mg": 89}),
    ("Grapes, Red or Green",        69,   0.7, 18.1, 0.2, 151, "1 cup (151g)",   {"fiber_g": 0.9}),
    ("Avocado",                    160,   2.0,  8.5, 14.7,  68, "½ avocado (68g)",{"fiber_g": 5.0, "potassium_mg": 345}),

    # ── Legumes ───────────────────────────────────────────────────────────────
    ("Black Beans, Cooked",        132,   8.9, 23.7, 0.5, 172, "1 cup cooked",   {"fiber_g": 8.7, "iron_mg": 3.6}),
    ("Chickpeas, Cooked",          164,   8.9, 27.4, 2.6, 164, "1 cup cooked",   {"fiber_g": 12.5, "iron_mg": 4.7}),
    ("Lentils, Cooked",            116,   9.0, 20.1, 0.4, 198, "1 cup cooked",   {"fiber_g": 7.8, "iron_mg": 6.6}),

    # ── Nuts & seeds ──────────────────────────────────────────────────────────
    ("Almonds",                    579,  21.2, 21.7, 49.9,  28, "1 oz (28g)",    {"fiber_g": 12.5, "calcium_mg": 264}),
    ("Peanuts, Dry Roasted",       585,  23.7, 21.5, 49.7,  28, "1 oz (28g)",   {"fiber_g": 8.5, "sodium_mg": 230}),
    ("Peanut Butter, Smooth",      588,  25.1, 20.1, 50.4,  32, "2 tbsp (32g)", {"fiber_g": 1.9, "sodium_mg": 152}),
    ("Walnuts",                    654,  15.2, 13.7, 65.2,  28, "1 oz (28g)",   {"fiber_g": 6.7, "omega3_g": 2.6}),
    ("Chia Seeds",                 486,  16.5, 42.1, 30.7,  28, "1 oz (28g)",   {"fiber_g": 34.4, "omega3_g": 5.0}),

    # ── Condiments & sauces ───────────────────────────────────────────────────
    ("Ketchup",                    112,   1.4, 27.3, 0.1,  17, "1 tbsp (17g)",  {"sodium_mg": 177, "sugar_g": 22.4}),
    ("Mayonnaise",                 680,   0.9,  0.6, 74.9, 14, "1 tbsp (14g)",  {"sodium_mg":  88}),
    ("Mustard, Yellow",             66,   4.4,  5.8, 4.2,   5, "1 tsp (5g)",    {"sodium_mg": 373}),
    ("Hot Sauce",                   23,   1.2,  4.6, 0.4,   5, "1 tsp (5g)",    {"sodium_mg": 1060}),
    ("Olive Oil",                  884,   0.0,  0.0, 100.0, 14, "1 tbsp (14g)", {}),
    ("Soy Sauce",                   53,   8.1,  4.9, 0.1,  16, "1 tbsp (16g)", {"sodium_mg": 5493}),
    ("Salsa",                       36,   1.7,  7.9, 0.2,  66, "¼ cup (66g)",  {"sodium_mg": 400, "fiber_g": 1.4}),

    # ── Pizza & fast food ─────────────────────────────────────────────────────
    ("Pizza, Cheese (from chain)",  266, 11.4, 33.4, 9.8, 107, "1 slice (107g)",{"sodium_mg": 640, "calcium_mg": 188}),
    ("Hot Dog, Plain",              290, 11.0,  2.0, 26.0, 52,  "1 frankfurter", {"sodium_mg": 760}),
    ("Fried Rice (restaurant)",    163,   4.5, 27.8, 4.0, 198, "1 cup",         {"sodium_mg": 580, "fiber_g": 0.8}),

    # ── Snacks ────────────────────────────────────────────────────────────────
    ("Potato Chips",               547,   7.0, 52.9, 35.7,  28, "1 oz (28g)",  {"sodium_mg": 149, "fiber_g": 1.5}),
    ("Popcorn, Air-Popped",        387,  13.0, 77.8, 4.5,  28,  "1 oz (28g)", {"fiber_g": 14.5, "sodium_mg": 8}),
    ("Pretzels",                   380,   9.6, 79.6, 3.5,  28,  "1 oz (28g)", {"sodium_mg": 966, "fiber_g": 2.8}),
    ("Granola Bar",                471,   9.0, 64.0, 20.0, 47,  "1 bar (47g)",{"fiber_g": 3.0, "sodium_mg": 190}),
    ("Crackers, Saltine",          421,   8.8, 74.0, 10.0, 30,  "~10 crackers",{"sodium_mg": 988, "fiber_g": 2.9}),
    ("Chocolate, Dark (70%)",      598,   7.8, 45.9, 42.6, 40,  "4 squares (40g)",{"fiber_g": 10.9, "iron_mg": 11.9}),
    ("Chocolate, Milk",            535,   7.7, 59.4, 29.7, 40,  "4 squares (40g)",{"calcium_mg": 189, "sodium_mg": 79}),

    # ── Beverages ─────────────────────────────────────────────────────────────
    ("Orange Juice",                45,   0.7, 10.4, 0.2, 248, "1 cup (248ml)", {"vitamin_c_mg": 67, "potassium_mg": 443}),
    ("Coffee, Black",                2,   0.3,  0.0, 0.0, 240, "1 cup (240ml)", {}),
    ("Protein Powder, Whey",       378,  79.2, 10.0, 5.5,  30,  "1 scoop (30g)",{"calcium_mg": 170, "sodium_mg": 120}),
    ("Protein Powder, Plant-Based",370,  74.0, 12.0, 6.0,  30,  "1 scoop (30g)",{"iron_mg": 5.0, "sodium_mg": 230}),
]
# fmt: on


def build_food_records() -> list[dict]:
    records = []
    for entry in _COMMON_FOODS:
        name, cal, pro, carb, fat, srv, srv_lbl, micros = entry
        records.append({
            "name": name,
            "brand": None,
            "barcode": None,
            "source": "common",
            "source_id": name.lower().replace(" ", "_").replace(",", "").replace("(", "").replace(")", "").replace("%", "pct").replace("/", "_"),
            "calories_per_100g": float(cal),
            "protein_per_100g": float(pro),
            "carbs_per_100g": float(carb),
            "fat_per_100g": float(fat),
            "serving_size_g": float(srv),
            "serving_label": srv_lbl,
            "micronutrients": micros if micros else None,
        })
    return records


def main():
    parser = base_argparser("Seed common everyday foods into the food database")
    args = parser.parse_args()

    records = build_food_records()
    print(f"Seeding {len(records)} common foods...")

    if args.dry_run:
        print("Dry run — no database writes.")
        for r in records:
            print(f"  {r['name']}: {r['calories_per_100g']} kcal / {r['protein_per_100g']}g protein")
        return

    sf = get_session_factory()
    stats = batch_insert_foods(
        sf,
        records,
        batch_size=args.batch_size,
        dry_run=False,
        verbose=args.verbose,
    )
    print(f"\nDone. inserted={stats['inserted']} skipped_existing={stats['skipped_existing']} invalid={stats['skipped_invalid']}")


if __name__ == "__main__":
    main()
