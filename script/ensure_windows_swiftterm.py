"""Prepare pinned SwiftTerm with LF sources (its terminfo generator requires LF).

Keep the user's Git configuration and SwiftPM checkouts untouched. The Studio
launcher passes the resulting local package through ADAEDITOR_SWIFTTERM_PACKAGE_PATH.
"""
from pathlib import Path
import subprocess
import sys

REVISION = "caa1bdd3f1396c5b0ed66121f299d1c8b42bc94c"
ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / ".build-tools" / ("swiftterm-" + REVISION[:12])


def git(*arguments):
    return subprocess.run(
        ["git", "-c", "core.autocrlf=false", *map(str, arguments)],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout


def main():
    if not (PACKAGE / "Package.swift").is_file():
        PACKAGE.mkdir(parents=True, exist_ok=True)
        if not (PACKAGE / ".git").is_dir():
            git("init", PACKAGE)
            git("-C", PACKAGE, "remote", "add", "origin", "https://github.com/migueldeicaza/SwiftTerm.git")
        git("-C", PACKAGE, "fetch", "--depth", "1", "origin", REVISION)
        git("-C", PACKAGE, "checkout", "--detach", REVISION)
    if git("-C", PACKAGE, "rev-parse", "HEAD").decode().strip() != REVISION:
        raise RuntimeError("Unexpected SwiftTerm revision in " + str(PACKAGE))
    # Recover a checkout created before LF normalization without resetting any source files.
    terminfo = PACKAGE / "swifterm-terminfo"
    data = terminfo.read_bytes()
    if b"\r\n" in data:
        terminfo.write_bytes(data.replace(b"\r\n", b"\n"))
    print(PACKAGE)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
