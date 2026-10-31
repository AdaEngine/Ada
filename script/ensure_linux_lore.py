#!/usr/bin/env python3
"""Prepare the pinned Linux Lore SDK or the shared native Swift package."""
import argparse
import platform

from ensure_lore import ensure_package as prepare_package, ensure_sdk, linux_target


def ensure(architecture=None):
    return ensure_sdk(linux_target(architecture or platform.machine()))


def ensure_package(architecture=None):
    return prepare_package(linux_target(architecture or platform.machine()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", action="store_true")
    parser.add_argument("--architecture", help="Defaults to this host's architecture")
    arguments = parser.parse_args()
    print(ensure_package(arguments.architecture) if arguments.package else ensure(arguments.architecture))
