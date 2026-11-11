#!/usr/bin/env python3
"""Linux cross-build worker invoked by native Windows Studio through WSL exec."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys

HOME = Path.home() / ".local/share/AdaStudio/BuildTools"


def run(arguments, *, env=None):
    print("+ " + " ".join(map(str, arguments)), flush=True)
    log_path = (env or {}).get("ADA_STUDIO_BUILD_LOG")
    if not log_path:
        subprocess.run(list(map(str, arguments)), env=env, check=True)
        return
    errors = []
    with open(log_path, "a", encoding="utf-8") as log:
        process = subprocess.Popen(list(map(str, arguments)), env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, errors="replace")
        for line in process.stdout:
            log.write(line)
            print(line, end="", flush=True)
            if "error:" in line.lower():
                errors.append(line.rstrip())
        code = process.wait()
    if code:
        for line in errors[-20:]:
            print(line, file=sys.stderr, flush=True)
        print(f"Full cross-build log: {log_path}", file=sys.stderr, flush=True)
        raise subprocess.CalledProcessError(code, arguments)


def scratch_directory(package, mode, product, swift_sdk, requested=None):
    cache_project = package.parent if package.name.startswith((".ada-aot-", ".ada-android-")) else package
    project_key = hashlib.sha256((str(cache_project) + product + swift_sdk).encode()).hexdigest()[:16]
    scratch = Path(requested).resolve() if requested else None
    if scratch:
        parts = scratch.parts
        windows_mount = len(parts) >= 3 and parts[1] == "mnt" and len(parts[2]) == 1 and parts[2].isalpha()
        # SwiftPM creates thousands of small files. Keep Windows-hosted build
        # caches on the Linux filesystem, outside disposable export directories.
        if windows_mount or (cache_project != package and scratch.is_relative_to(package)):
            scratch = None
    return (scratch or HOME / "builds" / mode / project_key).resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["web", "android"], required=True)
    for name in ["engine", "package", "output", "product", "swift-sdk"]:
        parser.add_argument("--" + name, required=True)
    for name in ["swift", "gravity", "scratch", "saga", "application-id", "label", "debug-keystore", "swan"]:
        parser.add_argument("--" + name)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--abi", choices=["arm64-v8a", "x86_64", "all"], default="arm64-v8a")
    parser.add_argument("--serve", action="store_true")
    args = parser.parse_args()
    version = args.swift_sdk.removeprefix("swift-").split("-RELEASE")[0]
    swift = Path(args.swift) if args.swift else HOME / f"swift-{version}/usr/bin/swift"
    if not swift.is_file():
        raise RuntimeError(f"Linux Swift {version} is missing. Run script/setup_windows_build_tools.ps1.")
    engine, package = Path(args.engine).resolve(), Path(args.package).resolve()
    env = os.environ.copy()
    # Windows PATH/proxy values are not Linux build settings.
    env["PATH"] = str(swift.parent) + os.pathsep + env.get("PATH", "/usr/bin:/bin")
    env.update(ADAENGINE_PACKAGE_PATH=str(engine), ADAENGINE_HEADLESS="0", ADAENGINE_DISABLE_SWAN="0")
    env.pop("ADAENGINE_GRAVITY_PACKAGE_PATH", None)
    if args.gravity:
        env["ADAENGINE_GRAVITY_PACKAGE_PATH"] = str(Path(args.gravity).resolve())
    scratch = scratch_directory(package, args.mode, args.product, args.swift_sdk, args.scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    env["ADA_STUDIO_BUILD_LOG"] = str(scratch / "build.log")
    os.chdir(package)
    if args.mode == "web":
        env.update(ADAENGINE_WEB_EXPORT="1", BUILD_WASM="1")
        if args.saga:
            env["ADAENGINE_SAGA_PACKAGE_PATH"] = str(Path(args.saga).resolve())
        command = [swift, "package", "--disable-sandbox", "--scratch-path", scratch / "host",
                   "--allow-writing-to-package-directory", "--allow-network-connections", "all", "export-web",
                   "--product", args.product, "--output", args.output, "--scratch-path", scratch / "wasm",
                   "--swift-sdk", args.swift_sdk, "--debug" if args.configuration == "debug" else "--release"]
        run(command, env=env)
        if args.serve:
            print(f"Serving {args.output} at http://127.0.0.1:8080", flush=True)
            run([sys.executable, engine / "Tools/Windows/serve_web.py", "--directory", args.output, "--port", "8080"])
        return
    env.update(ADAENGINE_ANDROID="1", SWAN_RUNTIME_ONLY="1",
               SWIFT_ANDROID_SWIFT=str(swift), SWIFT_ANDROID_SDK=args.swift_sdk,
               SWIFT_ANDROID_SDKS_PATH=str(Path.home() / ".swiftpm/swift-sdks"),
               ANDROID_HOME=str(HOME / "android-sdk"), ANDROID_NDK_HOME=str(HOME / "android-ndk-r28c"),
               JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64")
    swan = Path(args.swan).resolve() if args.swan else HOME / "swan-android"
    # A configured Swan must actually contain an Android artifact. The managed
    # copy is prepared against the exact Dawn/binding revision by the setup tool.
    if not (swan / "Dawn/dist/android.artifactbundle/info.json").is_file():
        swan = HOME / "swan-android"
    env.update(ADAENGINE_SWAN_PACKAGE_PATH=str(swan), SWAN_LOCAL_DAWN="Dawn/dist/android.artifactbundle")
    command = [sys.executable, engine / "Tools/Android/android.py", "build", "--package", package,
               "--product", args.product, "--application-id", args.application_id,
               "--label", args.label or args.product, "--abi", args.abi,
               "--configuration", args.configuration, "--scratch", scratch, "--output", args.output]
    if args.debug_keystore:
        command += ["--debug-keystore", args.debug_keystore]
    run(command, env=env)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Windows cross-build failed: {error}", file=sys.stderr)
        sys.exit(1)
