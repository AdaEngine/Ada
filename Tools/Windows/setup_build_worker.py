#!/usr/bin/env python3
"""Install isolated Linux cross-build tools for Windows Studio's WSL worker."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
HOME = Path.home() / ".local/share/AdaStudio/BuildTools"


def run(command, *, env=None, cwd=None):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, env=env, cwd=cwd)


def download(url, checksum=None):
    path = HOME / "downloads" / url.rsplit("/", 1)[-1]
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        partial = path.with_suffix(path.suffix + ".partial")
        print("Downloading " + url, flush=True)
        with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as stream:
            shutil.copyfileobj(response, stream, 1024 * 1024)
        partial.replace(path)
    if checksum:
        digest = hashlib.file_digest(path.open("rb"), "sha256").hexdigest()
        if digest != checksum:
            raise RuntimeError(f"Checksum mismatch for {path.name}")
    return path


def extract_zip(archive, directory):
    """NDK ZIPs contain executable modes and symlinks; extractall loses both."""
    root = directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as stream:
        for info in stream.infolist():
            destination = root / info.filename
            if not destination.parent.resolve().is_relative_to(root):
                raise RuntimeError("Archive path escapes the tool directory")
            mode = info.external_attr >> 16
            if info.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            if stat.S_ISLNK(mode):
                target = stream.read(info).decode()
                if not (destination.parent / target).resolve().is_relative_to(root):
                    raise RuntimeError("Archive symlink escapes the tool directory")
                if destination.is_symlink() or destination.exists():
                    destination.unlink()
                destination.symlink_to(target)
            else:
                with stream.open(info) as source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if mode & 0o777:
                    destination.chmod(mode & 0o777)


def swift(version):
    destination = HOME / f"swift-{version}"
    if not (destination / "usr/bin/swift").exists():
        archive = download(f"https://download.swift.org/swift-{version}-release/ubuntu2404/swift-{version}-RELEASE/swift-{version}-RELEASE-ubuntu24.04.tar.gz")
        with tarfile.open(archive) as stream:
            stream.extractall(HOME / "unpack", filter="data")
        (HOME / "unpack" / f"swift-{version}-RELEASE-ubuntu24.04").rename(destination)
    return destination / "usr/bin/swift"


def sdk(version, platform, checksum=None):
    compiler = swift(version)
    identifier = f"swift-{version}-RELEASE_{platform}"
    existing = subprocess.check_output([compiler, "sdk", "list"], text=True)
    if identifier not in existing:
        archive = download(f"https://download.swift.org/swift-{version}-release/{platform}-sdk/swift-{version}-RELEASE/{identifier}.artifactbundle.tar.gz", checksum)
        run([compiler, "sdk", "install", archive])
    return compiler


def android():
    sdk("6.4.0", "android", "21fb555122a3d801ad943d48df7ebffdd8824de61c25c180bb792d3edaee0b43")
    ndk = HOME / "android-ndk-r28c"
    if not (ndk / ".ada-extraction-v1").is_file():
        archive = download("https://dl.google.com/android/repository/android-ndk-r28c-linux.zip")
        extract_zip(archive, HOME)
        (ndk / ".ada-extraction-v1").touch()
    sdk_root = HOME / "android-sdk"
    manager = sdk_root / "cmdline-tools/latest/bin/sdkmanager"
    if not manager.is_file():
        archive = download("https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip")
        extract_zip(archive, sdk_root / "command-download")
        manager.parent.parent.parent.mkdir(parents=True, exist_ok=True)
        (sdk_root / "command-download/cmdline-tools").rename(manager.parent.parent)
        for executable in manager.parent.iterdir():
            executable.chmod(0o755)
    # Reuse licenses already accepted in the native Windows Android SDK.
    parser_licenses = os.environ.get("ADA_WINDOWS_ANDROID_LICENSES")
    if parser_licenses:
        shutil.copytree(parser_licenses, sdk_root / "licenses", dirs_exist_ok=True)
    env = os.environ.copy()
    env.update(ANDROID_NDK_HOME=str(ndk), JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64")
    run([manager, "--sdk_root=" + str(sdk_root), "platforms;android-36", "build-tools;36.0.0", "platform-tools"], env=env)
    bundles = Path.home() / ".swiftpm/swift-sdks"
    bundle = bundles / "swift-6.4.0-RELEASE_android.artifactbundle/swift-android"
    setup = bundle / "scripts/setup-android-sdk.sh"
    if setup.is_file():
        run(["bash", setup], env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--android", action="store_true")
    options = parser.parse_args()
    HOME.mkdir(parents=True, exist_ok=True)
    if options.web or not options.android:
        sdk("6.3.2", "wasm")
    if options.android or not options.web:
        android()
    print("Windows cross-build tools are ready.", flush=True)


if __name__ == "__main__":
    main()
