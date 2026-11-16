"""Build the optional NVIDIA NGX bridge (adaengine_ngx) against a locally installed DLSS SDK.

The SDK is downloaded by the developer (github.com/NVIDIA/DLSS) and is never copied into the repository: the bridge and the
NGX libraries are written to the output directory, which ``ADAENGINE_NGX_SDK_PATH`` or the game folder points at.
"""
from pathlib import Path
import shutil

from .context import ToolError

WINDOWS_FILES = (
    "include/nvsdk_ngx_vk.h",
    "include/nvsdk_ngx_helpers_vk.h",
    "include/nvsdk_ngx_helpers_dlssd_vk.h",
    "lib/Windows_x86_64/x64/nvsdk_ngx_d.lib",
    "lib/Windows_x86_64/rel/nvngx_dlss.dll",
    "lib/Windows_x86_64/rel/nvngx_dlssd.dll",
)


def required_files(host):
    """SDK files (relative to the SDK root) the bridge build needs."""
    return list(WINDOWS_FILES) if host == "windows" else []


def validate_sdk(sdk, host):
    """The required SDK files that are missing under ``sdk``."""
    return [name for name in required_files(host) if not (Path(sdk) / name).is_file()]


def bridge(ctx, args):
    """Builds ``adaengine_ngx`` and copies the NGX libraries next to it; returns the bridge path."""
    if ctx.host != "windows":
        raise ToolError("Building the NGX bridge is only supported on Windows for now")
    sdk = (args.sdk or Path(ctx.env.get("ADAENGINE_NGX_SDK_SOURCE", "") or ".")).resolve()
    missing = validate_sdk(sdk, ctx.host)
    if missing:
        raise ToolError("The NVIDIA DLSS SDK at " + str(sdk) + " is missing: " + ", ".join(missing)
                        + ". Clone https://github.com/NVIDIA/DLSS and pass --sdk PATH.")
    output = (args.output or ctx.cache / "ngx-bridge").resolve()
    library = output / "adaengine_ngx.dll"
    script = ctx.root / "Tools/NGXBridge/build.ps1"
    ctx.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Sdk", str(sdk), "-Output", str(output)])
    if not ctx.dry:
        for name in ("nvngx_dlss.dll", "nvngx_dlssd.dll"):
            shutil.copy2(sdk / "lib/Windows_x86_64/rel" / name, output / name)
    return library
