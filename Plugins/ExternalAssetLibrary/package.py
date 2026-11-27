"""Build the Store ZIP for the External Asset Library Studio plugin."""

import argparse
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    destination = parser.parse_args().output
    directory = Path(__file__).resolve().parent
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, mode="x", compression=zipfile.ZIP_STORED) as archive:
        for name in ("plugin.json", "ExternalAssetLibrary.ada"):
            entry = zipfile.ZipInfo(name)
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, (directory / name).read_bytes())


if __name__ == "__main__":
    main()
