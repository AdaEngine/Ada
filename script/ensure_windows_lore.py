#!/usr/bin/env python3
"""Prepare the pinned Windows Lore SDK or the shared native Swift package."""
import sys

from ensure_lore import ensure_package as prepare_package, ensure_sdk


def ensure():
    return ensure_sdk("windows_x86_64")


def ensure_package():
    return prepare_package("windows_x86_64")


if __name__ == "__main__":
    print(ensure_package() if "--package" in sys.argv[1:] else ensure())
