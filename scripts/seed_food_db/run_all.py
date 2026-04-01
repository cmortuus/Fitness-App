#!/usr/bin/env python3
"""Orchestrator — run all food database importers in sequence.

Usage:
    python scripts/seed_food_db/run_all.py                  # OFF + USDA
    python scripts/seed_food_db/run_all.py --off-only       # just Open Food Facts
    python scripts/seed_food_db/run_all.py --usda-only      # just USDA
    python scripts/seed_food_db/run_all.py --dry-run --limit 100
"""
import argparse
import subprocess
import sys
import os


def run_script(name: str, extra_args: list[str]):
    script = os.path.join(os.path.dirname(__file__), name)
    cmd = [sys.executable, script] + extra_args
    print(f"\n{'=' * 60}")
    print(f"Running: {' '.join(cmd)}")
    print(f"{'=' * 60}\n")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"\n{name} failed with exit code {result.returncode}")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Run food database importers")
    parser.add_argument("--off-only", action="store_true", help="Only run Open Food Facts import")
    parser.add_argument("--usda-only", action="store_true", help="Only run USDA import")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--batch-size", type=int, default=500)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    extra = []
    if args.dry_run:
        extra.append("--dry-run")
    if args.batch_size != 500:
        extra.extend(["--batch-size", str(args.batch_size)])
    if args.limit:
        extra.extend(["--limit", str(args.limit)])
    if args.verbose:
        extra.append("--verbose")

    run_off = not args.usda_only
    run_usda = not args.off_only

    ok = True
    # Always seed common foods first so basic staples are always searchable
    ok = run_script("seed_common.py", extra) and ok
    if run_off:
        ok = run_script("import_openfoodfacts.py", extra) and ok
    if run_usda:
        ok = run_script("import_usda.py", extra) and ok

    if ok:
        print("\nAll imports completed successfully!")
    else:
        print("\nSome imports failed. Check output above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
