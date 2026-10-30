#!/usr/bin/env python3
"""Prepare the pinned NGX SDK and build the Dawn/DLSS bridge without rebuilding Dawn."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SDK_REVISION = "9981c6350dc58c0ce21f024fd65e31e851c31689"


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def paths():
    sdk = Path(os.environ.get("ADAENGINE_DLSS_SDK_PATH", ROOT / ".build-tools/dlss-sdk")).resolve()
    if not sdk.exists():
        run("git", "clone", "--filter=blob:none", "--no-checkout", "https://github.com/NVIDIA/DLSS.git", sdk)
        run("git", "-C", sdk, "sparse-checkout", "set", "include", "lib/Windows_x86_64/x64", "lib/Windows_x86_64/rel")
        run("git", "-C", sdk, "checkout", SDK_REVISION)
    revision = subprocess.check_output(["git", "-C", str(sdk), "rev-parse", "HEAD"], text=True).strip()
    if revision != SDK_REVISION:
        raise RuntimeError(f"Expected DLSS SDK {SDK_REVISION}; found {revision}. Supply a separate SDK checkout.")
    candidates = list((ROOT / "Editor/.build/artifacts/swan/DawnLib").glob("*/windows_x86_64_release"))
    dawn = Path(os.environ.get("ADAENGINE_DAWN_PATH", candidates[0] if candidates else "" )).resolve()
    if not (dawn / "include/dawn/native/D3D12Backend.h").is_file():
        raise RuntimeError("Set ADAENGINE_DAWN_PATH to the SAME Dawn artifact used by Swan.")
    return sdk, dawn


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--stage-runtime", type=Path, help="Copy the pinned runtime and notice beside an already built executable")
    parser.add_argument("--output", type=Path, default=ROOT / ".build-tools/dlss-interop")
    args = parser.parse_args()
    sdk, dawn = paths()
    if args.stage_runtime:
        args.stage_runtime.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk / "lib/Windows_x86_64/rel/nvngx_dlss.dll", args.stage_runtime)
        shutil.copy2(sdk / "LICENSE.txt", args.stage_runtime / "NVIDIA-DLSS-LICENSE.txt")
        return
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    includes = [ROOT / "Sources/CWebGPUDLSS/include", sdk / "include", dawn / "include"]
    flags = ["-std=c++17", "-O2", "-g", "-fms-runtime-lib=dll", "-D_MT", "-D_DLL"]
    for path in includes:
        flags += ["-I", str(path)]
    objects = []
    for file in sorted((ROOT / "Sources/CWebGPUDLSS").glob("*.cpp")):
        obj = output / (file.stem + ".obj")
        run("clang++", *flags, "-c", file, "-o", obj)
        objects.append(str(obj))
    ngx = sdk / "lib/Windows_x86_64/x64/nvsdk_ngx_d.lib"
    # Dawn's shared-fence implementation uses this Windows 10 API. Older SDK
    # kernel32 import libs omit it; avoid umbrella mincore/OneCore CRT aliases.
    kernel = output / "AdaKernelBase.lib"
    run("llvm-dlltool", "-m", "i386:x86-64", "-d", ROOT / "Sources/CWebGPUDLSS/KernelBaseImports.def", "-l", kernel)
    manifest = dict(sdkRevision=SDK_REVISION, sdk=str(sdk), dawn=str(dawn), objects=objects,
                    dawnLibrarySHA256=hashlib.sha256((dawn / "webgpu_dawn.lib").read_bytes()).hexdigest(),
                    includePaths=[str(path) for path in includes], libraries=[str(ngx), str(kernel)])
    (output / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(sdk / "lib/Windows_x86_64/rel/nvngx_dlss.dll", output)
    shutil.copy2(sdk / "LICENSE.txt", output / "NVIDIA-DLSS-LICENSE.txt")
    if args.smoke:
        # Match the production executable's native dependencies, including bundled DXC.
        import yaml
        plan = yaml.load((ROOT / "Editor/.build/release.yaml").read_text(), Loader=yaml.CSafeLoader)
        link = next(command["args"] for command in plan["commands"].values()
                    if isinstance(command.get("args"), list) and "-emit-executable" in command["args"]
                    and any(str(arg).endswith("AdaEditor.exe") for arg in command["args"]))
        libraries = [str(dawn / "webgpu_dawn.lib"), str(ngx), str(kernel), "-ld3d12", "-ldxgi", "-ldxguid",
                     "-lole32", "-luser32", "-lshlwapi", "-lversion", "-lwinmm", "-ladvapi32", "-ldbghelp",
                     "-lucrt", "-lvcruntime", "-lmsvcrt", "-lmsvcprt",
                     "-Xlinker", "/NODEFAULTLIB:libcmt"]
        for index, arg in enumerate(link[:-1]):
            if arg == "-l": libraries += ["-l" + link[index + 1]]
            elif arg.startswith("-l") and arg not in ("-load-plugin-executable", "-libc", "-lwebgpu_dawn"): libraries.append(arg)
        run("clang++", *flags, ROOT / "Tools/DLSS/Smoke.cpp", *objects, *libraries,
            "-o", output / "DLSSSmoke.exe")
        for dll in ["dxcompiler.dll", "dxil.dll", "d3dcompiler_47.dll"]:
            source = next(dawn.rglob(dll), None)
            if source: shutil.copy2(source, output / dll)
        run(output / "DLSSSmoke.exe", cwd=output)
    print(output / "build.json", flush=True)


if __name__ == "__main__":
    main()
