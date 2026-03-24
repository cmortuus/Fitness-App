"""Proxy for external food databases (Open Food Facts + USDA FoodData Central).

All queries run server-side to avoid CORS issues and to merge results from
multiple sources into a unified format.
"""

import asyncio

import httpx

from app.config import get_settings

_TIMEOUT = httpx.Timeout(10.0, connect=5.0)

# USDA nutrient IDs — macros
_USDA_CALORIES = 1008
_USDA_PROTEIN = 1003
_USDA_CARBS = 1005
_USDA_FAT = 1004

# USDA nutrient IDs — micronutrients
_USDA_MICROS = {
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

# Open Food Facts nutriment keys → our micro keys
_OFF_MICROS = {
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
    "omega-3-fat_100g": "omega3_g",
}


def _normalize_off_product(product: dict) -> dict | None:
    """Normalize an Open Food Facts product into our common shape."""
    name = product.get("product_name") or product.get("product_name_en")
    if not name:
        return None
    nuts = product.get("nutriments", {})
    # Extract micronutrients
    micros = {}
    for off_key, our_key in _OFF_MICROS.items():
        val = nuts.get(off_key)
        if val is not None and val > 0:
            micros[our_key] = round(val, 3)
    return {
        "name": name,
        "brand": product.get("brands", "").split(",")[0].strip() or None,
        "source": "openfoodfacts",
        "source_id": product.get("code") or product.get("_id"),
        "barcode": product.get("code"),
        "calories_per_100g": nuts.get("energy-kcal_100g") or nuts.get("energy_100g"),
        "protein_per_100g": nuts.get("proteins_100g"),
        "carbs_per_100g": nuts.get("carbohydrates_100g"),
        "fat_per_100g": nuts.get("fat_100g"),
        "serving_size_g": _parse_serving(product.get("serving_size")),
        "serving_label": product.get("serving_size"),
        "micronutrients": micros or None,
    }


def _normalize_usda_food(food: dict) -> dict | None:
    """Normalize a USDA FoodData Central result into our common shape."""
    name = food.get("description")
    if not name:
        return None
    nutrients = {n["nutrientId"]: n.get("value", 0) for n in food.get("foodNutrients", [])}
    # Extract micronutrients
    micros = {}
    for usda_id, our_key in _USDA_MICROS.items():
        val = nutrients.get(usda_id)
        if val is not None and val > 0:
            micros[our_key] = round(val, 3)
    return {
        "name": name,
        "brand": food.get("brandName") or food.get("brandOwner"),
        "source": "usda",
        "source_id": str(food.get("fdcId", "")),
        "barcode": food.get("gtinUpc"),
        "calories_per_100g": nutrients.get(_USDA_CALORIES),
        "protein_per_100g": nutrients.get(_USDA_PROTEIN),
        "carbs_per_100g": nutrients.get(_USDA_CARBS),
        "fat_per_100g": nutrients.get(_USDA_FAT),
        "serving_size_g": 100.0,
        "serving_label": None,
        "micronutrients": micros or None,
    }


def _parse_serving(s: str | None) -> float:
    """Try to extract grams from a serving string like '100 g' or '1 cup (240ml)'."""
    if not s:
        return 100.0
    import re
    m = re.search(r"(\d+\.?\d*)\s*g", s, re.IGNORECASE)
    return float(m.group(1)) if m else 100.0


def _completeness(item: dict) -> int:
    """Score how many macro fields are filled (for dedup preference)."""
    return sum(1 for k in ("calories_per_100g", "protein_per_100g", "carbs_per_100g", "fat_per_100g")
               if item.get(k) is not None)


async def search_foods(query: str, page: int = 1, page_size: int = 15) -> list[dict]:
    """Search both Open Food Facts and USDA in parallel, merge and deduplicate."""
    settings = get_settings()

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        off_task = client.get(
            "https://world.openfoodfacts.org/cgi/search.pl",
            params={"search_terms": query, "page": page, "page_size": page_size, "json": 1},
        )
        usda_task = client.get(
            "https://api.nal.usda.gov/fdc/v1/foods/search",
            params={"query": query, "pageSize": page_size, "pageNumber": page, "api_key": settings.usda_api_key},
        )
        off_resp, usda_resp = await asyncio.gather(off_task, usda_task, return_exceptions=True)

    results: list[dict] = []

    # USDA results first (generally higher quality for US users)
    if isinstance(usda_resp, httpx.Response) and usda_resp.status_code == 200:
        for food in usda_resp.json().get("foods", []):
            item = _normalize_usda_food(food)
            if item:
                results.append(item)

    # Open Food Facts
    if isinstance(off_resp, httpx.Response) and off_resp.status_code == 200:
        for product in off_resp.json().get("products", []):
            item = _normalize_off_product(product)
            if item:
                results.append(item)

    # Deduplicate by lowercase name+brand, keeping the more complete entry
    seen: dict[str, dict] = {}
    for item in results:
        key = (item["name"].lower(), (item.get("brand") or "").lower())
        existing = seen.get(key)
        if not existing or _completeness(item) > _completeness(existing):
            seen[key] = item
    return list(seen.values())


async def lookup_barcode(barcode: str) -> dict | None:
    """Look up a barcode via Open Food Facts. Returns normalized food or None."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.get(f"https://world.openfoodfacts.org/api/v2/product/{barcode}.json")
    if resp.status_code != 200:
        return None
    data = resp.json()
    if data.get("status") != 1:
        return None
    return _normalize_off_product(data.get("product", {}))
