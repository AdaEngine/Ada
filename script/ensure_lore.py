#!/usr/bin/env python3
"""Prepare pinned native Lore SDKs and the shared Windows/Linux Swift port."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "Tools/Lore/toolchain.json").read_text())
NOTICES = ("LICENSE.txt", "THIRD-PARTY-NOTICES.txt")


def linux_target(machine):
    aliases = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "aarch64", "aarch64": "aarch64"}
    architecture = aliases.get(machine.lower())
    if architecture is None:
        raise RuntimeError("Lore supports Linux x86_64 and ARM64, not " + machine)
    return "linux_" + architecture


def files_for(target):
    if target == "windows_x86_64":
        return ("lore.h", "lore.dll.lib", "lore.dll") + NOTICES
    if target in ("linux_x86_64", "linux_aarch64"):
        return ("lore.h", "liblore.so") + NOTICES
    raise RuntimeError("Unsupported Lore SDK target: " + target)


def archive_files(archive, target):
    names = files_for(target)
    if target == "windows_x86_64":
        with zipfile.ZipFile(archive) as sdk:
            return {name: sdk.read(name) for name in names}
    with tarfile.open(archive, "r:gz") as sdk:
        result = {}
        for name in names:
            # The release has ./ prefixes. Never extract archive paths or links.
            try:
                member = sdk.getmember(name)
            except KeyError:
                member = sdk.getmember("./" + name)
            if not member.isfile():
                raise RuntimeError("Lore SDK entry must be a regular file: " + name)
            with sdk.extractfile(member) as stream:
                result[name] = stream.read()
        library = result["liblore.so"]
        machine = 62 if target == "linux_x86_64" else 183
        if len(library) < 20 or library[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", library, 18)[0] != machine:
            raise RuntimeError("Lore shared library does not match " + target)
        return result


def ensure_sdk(target):
    files_for(target)
    windows = target == "windows_x86_64"
    variable = "LORE_WINDOWS_SDK_PATH" if windows else "LORE_LINUX_SDK_PATH"
    suffix = "" if windows else "-" + target
    destination = Path(os.environ.get(variable, ROOT / ".build-tools" / ("lore-" + PIN["version"] + suffix)))
    destination.mkdir(parents=True, exist_ok=True)
    pin = PIN[target]
    archive = destination / ("liblore.zip" if windows else "liblore.tar.gz")
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
        with tempfile.TemporaryDirectory(dir=destination) as temporary:
            downloaded = Path(temporary) / archive.name
            urllib.request.urlretrieve(pin["url"], downloaded)
            if hashlib.sha256(downloaded.read_bytes()).hexdigest() != pin["sha256"]:
                raise RuntimeError("Lore SDK SHA-256 mismatch for " + target)
            shutil.copyfile(downloaded, archive)
    for name, data in archive_files(archive, target).items():
        path = destination / name
        if not path.exists() or path.read_bytes() != data:
            path.write_bytes(data)
    return destination.resolve()


def ensure_package(target):
    patch = ROOT / "Tools/Lore" / PIN["swift_patch_file"]
    digest = hashlib.sha256(patch.read_bytes()).hexdigest()
    package = ROOT / ".build-tools" / ("lore-swift-" + PIN["swift_patch_version"])
    marker = package / ".ada-native-port"

    def git(*arguments):
        return subprocess.check_output(["git", "-c", "core.autocrlf=false", "-c", "core.fsmonitor=false", *map(str, arguments)], stderr=subprocess.PIPE)

    if marker.exists():
        if marker.read_text().strip() != digest or git("-C", package, "rev-parse", "HEAD").decode().strip() != PIN["swift_revision"]:
            raise RuntimeError("Lore port checkout does not match the pin; bump swift_patch_version instead of overwriting it.")
    else:
        if (package / "Package.swift").exists():
            raise RuntimeError("Refusing to overwrite an existing unmarked Lore checkout: " + str(package))
        package.mkdir(parents=True, exist_ok=True)
        if not (package / ".git").exists():
            git("init", package)
            git("-C", package, "remote", "add", "origin", PIN["swift_repository"])
        git("-C", package, "fetch", "--depth", "1", "origin", PIN["swift_revision"])
        git("-C", package, "checkout", "--detach", PIN["swift_revision"])
        git("-C", package, "apply", "--check", patch)
        git("-C", package, "apply", patch)
        marker.write_text(digest + "\n")
    # Swift consumers do not inherit CLore's SDK search flags. Its public include
    # directory must contain the verified, matching interface header too.
    sdk = ensure_sdk(target)
    header = package / "Sources/CLore/include/lore.h"
    data = (sdk / "lore.h").read_bytes()
    if not header.exists() or header.read_bytes() != data:
        header.write_bytes(data)
    return package.resolve()
