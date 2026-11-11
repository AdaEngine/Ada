#!/usr/bin/env python3
"""Export the canonical Ada AI catalog as a Swift source pin for Ada Cloud."""

import argparse
import json
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[1] / "Sources/AdaEditor/Assets/AdaAIToolContract.json"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    raw = json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))
    # Use an extended delimiter that cannot occur in valid JSON strings.
    swift = '// Generated from AdaEngine with Editor/scripts/export-ada-ai-tool-contract.py.\n'
    swift += 'enum StudioToolCatalogData {\n    static let json = ####"""\n'
    swift += raw + '\n"""####\n}\n'
    if args.check:
        if args.output.read_text(encoding="utf-8") != swift:
            parser.exit(1, "Ada Cloud tool catalog differs from the canonical Studio catalog\n")
    else:
        args.output.write_text(swift, encoding="utf-8")


if __name__ == "__main__":
    main()
