#!/usr/bin/env python3
"""OCR-based food import — extract nutrition facts from product photos.

STATUS: STUB — implementation deferred until Mac Studio is available for
local compute, or when Claude Vision API budget is allocated.

PLANNED APPROACH:
1. Query DB for foods with barcodes but missing macro data
2. Fetch nutrition label photos from Open Food Facts image CDN
   (images.openfoodfacts.org/{barcode}/nutrition_front.jpg)
3. Use Claude Vision API to extract structured nutrition data from label
4. Parse and validate extracted values
5. Update existing food_items rows with the extracted macros

DEPENDENCIES (not yet added):
- anthropic (Claude Vision API)
- pillow (image handling)

ALTERNATIVE: --use-tesseract flag for free local OCR (lower accuracy)
- pytesseract + Tesseract OS package
- opencv-python for label region detection
"""
import sys


def main():
    print("OCR import is not yet implemented.")
    print("Run import_openfoodfacts.py or import_usda.py for structured bulk imports.")
    sys.exit(0)


if __name__ == "__main__":
    main()
