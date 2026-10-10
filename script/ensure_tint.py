#!/usr/bin/env python3
"""Build and verify the pinned SPIR-V -> WGSL host tool outside shared .build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / "Tools/Tint/toolchain.json").read_text())


def run(args, **kwargs):
    subprocess.run([str(value) for value in args], check=True, stdout=sys.stderr, **kwargs)


def verify(executable, work):
    # Minimal SPIR-V 1.0 vertex shader: gl_Position = vec4(0, 0, 0, 1).
    # This exercises the actual reader/writer rather than accepting --help output.
    words = [0x07230203, 0x00010000, 0, 12, 0,
             0x00020011, 1, 0x0003000e, 0, 1,
             0x0006000f, 0, 10, 0x6e69616d, 0, 9,
             0x00040047, 9, 11, 0,
             0x00020013, 1, 0x00030021, 2, 1,
             0x00030016, 3, 32, 0x00040017, 4, 3, 4,
             0x00040020, 5, 3, 4, 0x0004002b, 3, 6, 0,
             0x0004002b, 3, 7, 0x3f800000,
             0x0007002c, 4, 8, 6, 6, 6, 7, 0x0004003b, 5, 9, 3,
             0x00050036, 1, 10, 0, 2, 0x000200f8, 11,
             0x0003003e, 9, 8, 0x000100fd, 0x00010038]
    work.mkdir(parents=True, exist_ok=True)
    fixture = work / "tint-smoke.vert.spv"
    fixture.write_bytes(struct.pack("<" + "I" * len(words), *words))
    result = subprocess.run([str(executable), str(fixture), "--format", "wgsl",
                             "--allow-non-uniform-derivatives", "true"],
                            check=True, capture_output=True, text=True)
    if "@vertex" not in result.stdout or "@builtin(position)" not in result.stdout:
        raise RuntimeError("Tint did not produce the expected WGSL vertex shader")
    (work / "tint-smoke.vert.wgsl").write_text(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify cache/hash and SPIR-V smoke without building")
    parser.add_argument("--cache", type=Path, default=Path(os.environ.get("ADAENGINE_TINT_CACHE", ROOT / ".build-tools/tint")))
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    architecture = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
    host = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}[platform.system()]
    identifier = architecture + "-" + host
    revision = PIN["revision"]
    cache = args.cache.resolve()
    work = cache / revision
    source = work / "source"
    build = work / "build" / identifier
    name = "tint.exe" if host == "windows" else "tint"
    installed = cache / "bin" / identifier / name
    manifest = installed.parent / "toolchain.json"
    installed.parent.mkdir(parents=True, exist_ok=True)
    # Serialize independent dev commands using this cache; never delete a shared build.
    with (cache / "build.lock").open("a+b") as lock:
        if host == "windows":
            import msvcrt
            if lock.tell() == 0:
                lock.write(b"\0")
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        valid = installed.is_file() and manifest.is_file()
        if valid:
            metadata = json.loads(manifest.read_text())
            digest = hashlib.sha256(installed.read_bytes()).hexdigest()
            valid = metadata.get("revision") == revision and metadata.get("sha256") == digest
        if not valid:
            if args.check:
                raise RuntimeError("Verified Tint cache is missing; run script/ensure_tint.py")
            for tool in ("git", "cmake", "ninja"):
                if not shutil.which(tool):
                    raise RuntimeError("Required tool is missing: " + tool)
            source.mkdir(parents=True, exist_ok=True)
            if not (source / ".git").exists():
                run(["git", "-C", source, "init"])
            head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True)
            if head.returncode:
                run(["git", "-C", source, "fetch", "--depth", "1", PIN["repository"], revision])
                run(["git", "-C", source, "checkout", "--detach", "FETCH_HEAD"])
            elif head.stdout.strip() != revision:
                raise RuntimeError("Cache source has another revision; refusing to reset it")
            flags = ["CMAKE_BUILD_TYPE=Release", "DAWN_FETCH_DEPENDENCIES=ON", "DAWN_BUILD_MONOLITHIC_LIBRARY=OFF",
                     "DAWN_BUILD_SAMPLES=OFF", "DAWN_BUILD_TESTS=OFF", "DAWN_ENABLE_D3D11=OFF", "DAWN_ENABLE_D3D12=OFF",
                     "DAWN_ENABLE_METAL=OFF", "DAWN_ENABLE_VULKAN=OFF", "DAWN_ENABLE_DESKTOP_GL=OFF", "DAWN_ENABLE_OPENGLES=OFF",
                     "DAWN_USE_GLFW=OFF", "TINT_BUILD_TESTS=OFF", "TINT_BUILD_SPV_READER=ON", "TINT_BUILD_WGSL_WRITER=ON",
                     "TINT_BUILD_HLSL_WRITER=OFF", "TINT_BUILD_MSL_WRITER=OFF", "TINT_BUILD_GLSL_WRITER=OFF", "TINT_BUILD_SPV_WRITER=OFF"]
            run(["cmake", "-S", source, "-B", build, "-G", "Ninja", *["-D" + flag for flag in flags]])
            run(["cmake", "--build", build, "--target", "tint_cmd_tint_cmd", "--parallel", max(1, args.jobs)])
            executable = build / name
            verify(executable, work)
            pending = installed.with_suffix(".pending")
            shutil.copy2(executable, pending)
            pending.chmod(0o755)
            pending.replace(installed)
            manifest.write_text(json.dumps({**PIN, "platform": identifier,
                                            "sha256": hashlib.sha256(installed.read_bytes()).hexdigest()}, indent=2) + "\n")
        verify(installed, work)
        print(installed)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Tint bootstrap failed: " + str(error), file=sys.stderr)
        sys.exit(1)
