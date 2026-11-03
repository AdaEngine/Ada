#!/usr/bin/env python3
"""AdaEngine development CLI. Run `python ada_tool.py --help`. Requires Python 3.9+."""
import sys

if sys.version_info < (3, 9):
    sys.exit("ada_tool requires Python 3.9 or newer")

from script.ada_tools.cli import main

if __name__ == "__main__":
    sys.exit(main())
