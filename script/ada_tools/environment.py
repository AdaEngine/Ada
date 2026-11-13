"""Prepare native/web toolchains and report actionable, offline diagnostics."""
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from .context import PIN, ToolError, download, extract_tar, extract_zip


def swift_version(ctx):
    ok, output = ctx.probe([ctx.swift, "--version"])
    match = re.search(r"Swift version (\d+\.\d+(?:\.\d+)?)", output)
    return match.group(1) if ok and match else None


def require_swift(ctx):
    expected = PIN["swift"][ctx.host]
    if not ctx.dry and swift_version(ctx) != expected:
        raise ToolError(f"Swift {expected} is required for this host. Run: python ada_tool.py prepare swift")


def refresh_windows_paths(ctx):
    """Pick up newly installed tools without re-entering an initialized vcvars shell."""
    if ctx.dry:
        return
    import winreg
    for hive, key in [(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
                      (winreg.HKEY_CURRENT_USER, "Environment")]:
        with winreg.OpenKey(hive, key) as registry:
            path, _ = winreg.QueryValueEx(registry, "Path")
            for value in reversed(os.path.expandvars(path).split(os.pathsep)):
                if value:
                    ctx.prepend(value, persist=False)


def compatible_msvc(version):
    match = re.match(r"^(\d+)\.(\d+)(?:\.|$)", version.strip())
    minimum = tuple(map(int, PIN["windows_msvc_minimum"].split(".")))
    return bool(match and tuple(map(int, match.groups())) >= minimum)


def windows_environment(ctx):
    """Refresh installer PATH and import MSVC without modifying the user's shell."""
    if getattr(ctx, "windows_ready", False):
        return
    if ctx.dry:
        print("Prepare the Visual Studio x64 developer environment", file=sys.stderr)
        return
    refresh_windows_paths(ctx)
    vswhere = Path(ctx.env.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
    if not vswhere.is_file():
        raise ToolError("Visual Studio C++ Build Tools are missing; run prepare studio")
    install = ctx.run([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                       "-property", "installationPath"], capture=True)
    if not install:
        raise ToolError("Install Visual Studio 2022 C++ tools and Windows 11 SDK: python ada_tool.py prepare studio")
    script = Path(install) / "VC/Auxiliary/Build/vcvars64.bat"
    # Only the trusted VS installation path enters cmd; no user CLI arguments do.
    command = f'""{script}" >nul && set"'
    output = ctx.run(["cmd.exe", "/d", "/s", "/c", command], capture=True)
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if separator and key:
            ctx.env[key.upper() if key.lower() == "path" else key] = value
    version = ctx.env.get("VCToolsVersion", "")
    if not compatible_msvc(version):
        raise ToolError(f"MSVC {version or 'unknown'} is too old for the pinned Dawn runtime; requires "
                        f"{PIN['windows_msvc_minimum']}+ (Visual Studio 2022 17.14+). Run: python ada_tool.py prepare studio")
    # Persist the Visual Studio tools' locations, but not arbitrary process secrets.
    for directory in reversed(ctx.env.get("PATH", "").split(os.pathsep)):
        if directory and Path(directory).is_relative_to(Path(install)):
            ctx.prepend(directory)
    for relative in ("Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin", "Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja"):
        directory = Path(install) / relative
        if directory.is_dir():
            ctx.prepend(directory)
    for directory in reversed(list(ctx.bins)):
        ctx.prepend(directory)
    ctx.windows_ready = True


def system_dependencies(ctx):
    if ctx.host == "windows":
        if not ctx.which("winget") and not ctx.dry:
            raise ToolError("Install App Installer (WinGet), then rerun prepare")
        packages = [("git", "Git.Git"), ("cmake", "Kitware.CMake"), ("ninja", "Ninja-build.Ninja")]
        for executable, package in packages:
            if not ctx.which(executable):
                ctx.run(["winget", "install", "--id", package, "--exact", "--source", "winget",
                         "--accept-source-agreements", "--accept-package-agreements"])
        vswhere = Path(ctx.env.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Microsoft Visual Studio/Installer/vswhere.exe"
        ok, output = ctx.probe([vswhere, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                                "Microsoft.VisualStudio.Component.Windows11SDK.22621", "-property", "installationPath"])
        if not ok or not output:
            ctx.run(["winget", "install", "--id", "Microsoft.VisualStudio.2022.BuildTools", "--exact", "--source", "winget",
                     "--accept-source-agreements", "--accept-package-agreements", "--override",
                     "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"])
        else:
            version_file = Path(output.strip()) / "VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"
            version = version_file.read_text(encoding="utf-8-sig").strip() if version_file.is_file() else ""
            if not compatible_msvc(version):
                # Update the selected installation, including Community/Professional.
                # A bootstrapper without the update verb tries to install it again.
                ctx.run_elevated([vswhere.parent / "setup.exe", "update", "--installPath", output.strip(), "--passive", "--norestart"])
    elif ctx.host == "macos":
        if not ctx.which("brew") and not ctx.dry:
            raise ToolError("Install Homebrew (https://brew.sh) and Xcode, then rerun prepare")
        packages = [package for tool, package in [("cmake", "cmake"), ("ninja", "ninja"), ("xcodegen", "xcodegen"),
                                                  ("swiftly", "swiftly")] if not ctx.which(tool)]
        if packages:
            ctx.run(["brew", "install", *packages])
    else:
        if not ctx.which("apt-get") and not ctx.dry:
            raise ToolError("Automatic system setup supports Debian/Ubuntu; install the packages in Documentation/Linux.md, then use --skip-system")
        prefix = [] if hasattr(os, "geteuid") and os.geteuid() == 0 else ["sudo"]
        ctx.run([*prefix, "apt-get", "update"])
        ctx.run([*prefix, "apt-get", "install", "-y", "build-essential", "clang", "lld", "cmake", "ninja-build", "pkg-config", "git",
                 "curl", "unzip", "zip", "gnupg2", "ca-certificates", "libx11-dev", "libasound2-dev", "libpulse0", "libvulkan-dev",
                 "mesa-vulkan-drivers", "vulkan-tools", "libcurl4-openssl-dev", "libicu-dev", "libxml2-dev", "libsqlite3-dev",
                 "libncurses-dev", "libedit-dev", "libblocksruntime-dev", "libpython3-dev", "zenity"])


def prepare_swift(ctx, skip_system=False):
    version = PIN["swift"][ctx.host]
    if swift_version(ctx) == version:
        metadata = ctx.run([ctx.swift, "-print-target-info"], capture=True)
        if metadata:
            # Swiftly's launcher can later select another version. Save the real
            # compiler rather than the launcher so future CLI calls stay pinned.
            runtime = Path(json.loads(metadata)["paths"]["runtimeResourcePath"])
            suffix = "swift.exe" if ctx.host == "windows" else "swift"
            candidate = runtime.parent.parent / "bin" / suffix
            ctx.swift = str(candidate if candidate.is_file() else Path(ctx.which(ctx.swift) or ctx.swift))
            if ctx.host == "windows":
                for directory in json.loads(metadata)["paths"].get("runtimeLibraryPaths", []):
                    ctx.prepend(directory)
            ctx.prepend(Path(ctx.swift).parent)
            ctx.set("ADA_TOOL_SWIFT", ctx.swift)
        return
    if ctx.host == "windows":
        ctx.run(["winget", "install", "--id", "Swift.Toolchain", "--exact", "--version", version, "--source", "winget",
                 "--accept-source-agreements", "--accept-package-agreements"])
        refresh_windows_paths(ctx)
        ctx.swift = ctx.which("swift") or "swift"
    else:
        if ctx.host == "linux" and not ctx.which("swiftly"):
            arch = "aarch64" if ctx.arch == "arm64" else ctx.arch
            archive = download(ctx, f"https://download.swift.org/swiftly/linux/swiftly-{arch}.tar.gz", "swiftly.tar.gz")
            bootstrap = ctx.cache / "swiftly-bootstrap"
            if not ctx.dry:
                bootstrap.mkdir(parents=True, exist_ok=True)
                extract_tar(archive, bootstrap)
            ctx.run([bootstrap / "swiftly", "init", "--assume-yes", "--skip-install", "--quiet-shell-followup"])
            default = Path.home() / ".local/share/swiftly"
            ctx.prepend(Path(ctx.env.get("SWIFTLY_BIN_DIR", str(default / "bin"))))
        elif ctx.host == "macos":
            ready, _ = ctx.probe(["swiftly", "list"])
            if not ready:
                ctx.run(["swiftly", "init", "--assume-yes", "--skip-install", "--quiet-shell-followup"])
        post_install = ctx.cache / "swift-post-install.sh"
        if not ctx.dry:
            ctx.cache.mkdir(parents=True, exist_ok=True)
            if post_install.exists():
                post_install.unlink()
        ctx.run(["swiftly", "install", version, "--assume-yes", "--post-install-file", post_install])
        if post_install.is_file() and not ctx.dry:
            if skip_system:
                raise ToolError("Swift needs system prerequisites; review and run " + str(post_install) + ", then rerun prepare")
            ctx.run(["bash", post_install])
        # Resolve a toolchain path without changing the user's global selection/.swift-version.
        selected = ctx.run(["swiftly", "run", "+" + version, "swift", "-print-target-info"], capture=True)
        if selected:
            runtime = Path(json.loads(selected)["paths"]["runtimeResourcePath"])
            ctx.swift = str(runtime.parent.parent / "bin/swift")
        else:
            ctx.swift = str(ctx.cache / ("swift-" + version) / "usr/bin/swift")
        ctx.prepend(Path(ctx.swift).parent)
    ctx.set("ADA_TOOL_SWIFT", ctx.swift)
    require_swift(ctx)
    if ctx.host == "windows" and not ctx.dry:
        metadata = json.loads(ctx.run([ctx.swift, "-print-target-info"], capture=True))
        for directory in metadata["paths"].get("runtimeLibraryPaths", []):
            ctx.prepend(directory)
        ctx.prepend(Path(ctx.swift).parent)


def prepare_node(ctx):
    version = PIN["node"]
    ok, output = ctx.probe(["node", "--version"])
    if ok and node_compatible(output):
        return
    host = {"windows": "win", "macos": "darwin", "linux": "linux"}[ctx.host]
    arch = "x64" if ctx.arch == "x86_64" else "arm64"
    name = f"node-v{version}-{host}-{arch}"
    extension = ".zip" if ctx.host == "windows" else ".tar.gz"
    base = f"https://nodejs.org/dist/v{version}/"
    sums = download(ctx, base + "SHASUMS256.txt", "node-SHASUMS256.txt")
    checksum = None
    if not ctx.dry:
        checksum = next((line.split()[0] for line in sums.read_text().splitlines() if line.split()[-1] == name + extension), None)
        if not checksum:
            raise ToolError("Node archive is absent from the official SHA-256 manifest")
    archive = download(ctx, base + name + extension, name + extension, checksum)
    destination = ctx.cache / "node" / name
    if not ctx.dry and not destination.exists():
        (extract_zip if ctx.host == "windows" else extract_tar)(archive, destination.parent)
    ctx.prepend(destination if ctx.host == "windows" else destination / "bin")


def node_compatible(output):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", output.strip())
    return bool(match and tuple(map(int, match.groups())) >= tuple(map(int, PIN["node"].split("."))))


def pnpm(ctx, *arguments, cwd=None):
    package = json.loads((ctx.root / "Editor/WebUI/package.json").read_text(encoding="utf-8"))["packageManager"]
    version = package.split("@", 1)[1]
    home = ctx.cache / ("pnpm-" + version)
    executable = home / "node_modules/pnpm/bin/pnpm.cjs"
    if not executable.is_file():
        actual = ctx.run(["node", "-p", "process.execPath"], capture=True)
        node = Path(actual or ctx.which("node") or ctx.cache / "node/bin/node")
        candidates = [node.parent / ("node_modules/npm/bin/npm-cli.js" if ctx.host == "windows" else "../lib/node_modules/npm/bin/npm-cli.js")]
        if ctx.host == "linux":
            candidates.append(Path("/usr/share/nodejs/npm/bin/npm-cli.js"))
        npm = next((path for path in candidates if path.is_file()), candidates[0])
        if not npm.is_file() and not ctx.dry:
            raise ToolError("Node's npm CLI is missing; run prepare playground")
        ctx.run([node, npm, "install", "--prefix", home, "--no-audit", "--no-fund", package])
    return ctx.run(["node", executable, *arguments], cwd=cwd or ctx.root / "Editor/WebUI")


def prepare_linux_swan(ctx):
    pin = PIN["linux_swan"]
    source = ctx.cache / ("swan-source-" + pin["revision"])
    stage = ctx.cache / ("swan-" + pin["revision"])
    if not (source / ".git").is_dir():
        ctx.run(["git", "init", source])
        ctx.run(["git", "-C", source, "fetch", "--depth", "1", pin["repository"], pin["revision"]])
        ctx.run(["git", "-C", source, "checkout", "--detach", "FETCH_HEAD"])
    revision = ctx.run(["git", "-C", source, "rev-parse", "HEAD"], capture=True)
    if revision and revision != pin["revision"]:
        raise ToolError("Unexpected Swan revision; refusing to reset " + str(source))
    ctx.helper("prepare_swan_linux.py", source, stage, fallback=stage)
    artifact = stage / "DawnLinux.artifactbundle"
    if not (artifact / "info.json").is_file():
        archive = download(ctx, pin["dawn_url"], "dawn-linux.zip", pin["dawn_sha256"])
        if not ctx.dry:
            with tempfile.TemporaryDirectory(prefix="dawn-", dir=ctx.cache) as work:
                work = Path(work)
                extract_zip(archive, work)
                manifests = list(work.rglob("*.artifactbundle/info.json"))
                if len(manifests) != 1:
                    raise ToolError("Expected one Linux Dawn artifact bundle")
                manifests[0].parent.rename(artifact)
    ctx.set("ADAENGINE_SWAN_PACKAGE_PATH", stage)
    ctx.set("SWAN_LOCAL_DAWN", artifact.name)


def native_dependencies(ctx):
    ctx.set("ADAENGINE_PACKAGE_PATH", ctx.root)
    ctx.set("ADAENGINE_GRAVITY_PACKAGE_PATH", ctx.env.get("ADAENGINE_GRAVITY_PACKAGE_PATH", ctx.root / "Sources/gravity-lang"))
    ctx.env.update(ADAENGINE_HEADLESS="0", ADAENGINE_DISABLE_SWAN="0")
    if ctx.host in ("windows", "linux"):
        helper = "ensure_windows_lore.py" if ctx.host == "windows" else "ensure_linux_lore.py"
        variable = "LORE_WINDOWS_SDK_PATH" if ctx.host == "windows" else "LORE_LINUX_SDK_PATH"
        ctx.set(variable, ctx.helper(helper))
        if not ctx.env.get("ADAEDITOR_LORE_PACKAGE_PATH"):
            ctx.set("ADAEDITOR_LORE_PACKAGE_PATH", ctx.helper(helper, "--package"))
        if not ctx.env.get("ADA_MCP_LOCAL_PATH"):
            ctx.set("ADA_MCP_LOCAL_PATH", ctx.helper("ensure_windows_mcp.py"))
        if ctx.host == "windows":
            ctx.prepend(ctx.env[variable])
            if not ctx.env.get("ADAEDITOR_SWIFTTERM_PACKAGE_PATH"):
                ctx.set("ADAEDITOR_SWIFTTERM_PACKAGE_PATH", ctx.helper("ensure_windows_swiftterm.py"))
            ctx.helper("ensure_windows_icon.py")
            ctx.helper("ensure_windows_export_tools.py")
        else:
            ctx.set("LD_LIBRARY_PATH", ctx.env[variable] + os.pathsep + ctx.env.get("LD_LIBRARY_PATH", ""))
            if not ctx.env.get("ADAENGINE_SWAN_PACKAGE_PATH") or not ctx.env.get("SWAN_LOCAL_DAWN"):
                prepare_linux_swan(ctx)
            # Build the bundled native AdaScript compiler for the standalone SDK.
            gravity = ctx.env["ADAENGINE_GRAVITY_PACKAGE_PATH"]
            ctx.run(["cmake", "-S", gravity, "-B", ctx.cache / "gravity", "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release"])
            ctx.run(["cmake", "--build", ctx.cache / "gravity", "--target", "gravity", "--parallel", ctx.jobs])
            if not ctx.dry:
                import shutil
                shutil.copy2(ctx.cache / "gravity/bin/gravity", Path(gravity) / "gravity")


def wsl(ctx, arguments):
    if not ctx.which("wsl.exe") and not ctx.dry:
        raise ToolError("Install WSL 2 with Ubuntu 24.04: wsl --install -d Ubuntu-24.04; then run prepare wasm")
    root = ctx.run(["wsl.exe", "--exec", "wslpath", "-a", "-u", ctx.root], capture=True) or "/mnt/<drive>/AdaEngine"
    environment = []
    if saga := ctx.env.get("ADAENGINE_SAGA_PACKAGE_PATH"):
        if not saga.startswith("/"):
            saga = ctx.run(["wsl.exe", "--exec", "wslpath", "-a", "-u", saga], capture=True) or saga
        environment = ["env", f"ADAENGINE_SAGA_PACKAGE_PATH={saga}"]
    return ctx.run(["wsl.exe", "--cd", root, "--exec", *environment, "python3", root + "/ada_tool.py", *arguments])


def prepare(ctx, args):
    selected = set(args.components or ["studio", "wasm", "playground"])
    native = bool(selected - {"playground", "wasm"}) or ("wasm" in selected and ctx.host != "windows")
    if not args.skip_system and native:
        system_dependencies(ctx)
    if ctx.host == "windows" and native:
        windows_environment(ctx)
    if "studio" in selected or "swift" in selected or ("wasm" in selected and ctx.host != "windows"):
        prepare_swift(ctx, args.skip_system)
    if "studio" in selected:
        native_dependencies(ctx)
    if "tint" in selected:
        ctx.set("TINT_EXECUTABLE", ctx.helper("ensure_tint.py", "--jobs", ctx.jobs))
    if "wasm" in selected:
        if ctx.host == "windows":
            if not ctx.which("wsl.exe") and not ctx.dry:
                raise ToolError("Enable WSL with Ubuntu 24.04 first: wsl --install -d Ubuntu-24.04")
            if args.skip_system:
                root = ctx.run(["wsl.exe", "--exec", "wslpath", "-a", "-u", ctx.root], capture=True) or "/mnt/<drive>/AdaEngine"
                ctx.run(["wsl.exe", "--exec", "python3", root + "/Tools/Windows/setup_build_worker.py", "--web"])
            else:
                ctx.powershell(ctx.root / "script/setup_windows_build_tools.ps1", "-WebOnly")
        else:
            sdk = PIN["wasm"]
            existing = ctx.run([ctx.swift, "sdk", "list"], capture=True)
            if sdk["sdk"] not in existing.splitlines():
                ctx.run([ctx.swift, "sdk", "install", sdk["url"], "--checksum", sdk["sha256"]])
    if "playground" in selected:
        prepare_node(ctx)
        pnpm(ctx, "install", "--frozen-lockfile")
    ctx.save()
    print("Preparation complete" + (" (dry run)" if ctx.dry else f"; saved host configuration: {ctx.cache / 'environment.json'}"))


def doctor(ctx, args):
    checks = []

    def add(name, ok, detail, fix="", required=True):
        checks.append(dict(name=name, ok=bool(ok), detail=detail, fix=fix, required=required))

    profile = args.profile
    studio = profile in ("all", "studio")
    wasm = profile in ("all", "wasm")
    frontend = profile in ("all", "playground")
    add("Python", sys.version_info >= (3, 9), sys.version.split()[0], "Install Python 3.9+")
    if studio and ctx.host == "windows":
        try:
            windows_environment(ctx)
            add("Visual Studio C++ / SDK", True, ctx.env.get("WindowsSdkDir", "MSVC environment loaded"))
        except (OSError, ToolError) as error:
            add("Visual Studio C++ / SDK", False, str(error), "python ada_tool.py prepare studio")
    if studio or (wasm and ctx.host != "windows"):
        expected = PIN["swift"][ctx.host]
        actual = swift_version(ctx)
        add("Swift", actual == expected, f"{actual or 'missing'}; expected {expected}", "python ada_tool.py prepare swift")
        for tool in ("git", "cmake", "ninja"):
            add(tool, ctx.which(tool), ctx.which(tool) or "missing", "python ada_tool.py prepare studio")
        saga_override = ctx.env.get("ADAENGINE_SAGA_PACKAGE_PATH")
        if saga_override or (studio and ctx.host != "macos"):
            saga = Path(saga_override or ctx.root.parent / "SAGA")
            add("SAGA", (saga / "Package.swift").is_file(), str(saga), "Set ADAENGINE_SAGA_PACKAGE_PATH to the local SAGA checkout")
        else:
            add("SAGA", True, "Revision managed by SwiftPM")
    if studio:
        if ctx.host == "windows":
            add("Windows architecture", ctx.arch == "x86_64", ctx.arch, "Studio packaging currently requires Windows x64")
            add("C++ toolchain", ctx.which("cl") or ctx.which("clang-cl"), "MSVC/clang-cl and Windows SDK", "python ada_tool.py prepare studio")
        elif ctx.host == "macos":
            ok, output = ctx.probe(["xcodebuild", "-version"])
            add("Xcode", ok, output, "Install Xcode and select it with xcode-select")
            add("XcodeGen", ctx.which("xcodegen"), ctx.which("xcodegen") or "missing", "brew install xcodegen")
        else:
            swan = Path(ctx.env.get("ADAENGINE_SWAN_PACKAGE_PATH", "/__missing_swan__"))
            dawn = swan / ctx.env.get("SWAN_LOCAL_DAWN", "__missing_dawn__")
            add("Linux Swan/Dawn", (swan / "Package.swift").is_file() and (dawn / "info.json").is_file(),
                ctx.env.get("ADAENGINE_SWAN_PACKAGE_PATH", "not prepared"), "python ada_tool.py prepare studio")
            for tool in ("clang", "pkg-config", "zenity"):
                add(tool, ctx.which(tool), ctx.which(tool) or "missing", "python ada_tool.py prepare studio")
            ok, output = ctx.probe(["pkg-config", "--modversion", "x11", "alsa"])
            add("X11/ALSA development libraries", ok, output, "python ada_tool.py prepare studio")
            add("X11 display", ctx.env.get("DISPLAY"), ctx.env.get("DISPLAY", "not set"), "Start an X11/XWayland/WSLg session", required=False)
        if ctx.host in ("windows", "linux"):
            from script.ensure_lore import PIN as lore_pin, linux_target
            target = "windows_x86_64" if ctx.host == "windows" else linux_target(ctx.arch)
            suffix = "" if ctx.host == "windows" else "-" + target
            variable = "LORE_WINDOWS_SDK_PATH" if ctx.host == "windows" else "LORE_LINUX_SDK_PATH"
            sdk = Path(ctx.env.get(variable, ctx.root / ".build-tools" / ("lore-" + lore_pin["version"] + suffix)))
            library = "lore.dll" if ctx.host == "windows" else "liblore.so"
            package = Path(ctx.env.get("ADAEDITOR_LORE_PACKAGE_PATH", ctx.root / ".build-tools" / ("lore-swift-" + lore_pin["swift_patch_version"])))
            add("Lore SDK", (sdk / library).is_file() and (sdk / "lore.h").is_file(), str(sdk), "python ada_tool.py prepare studio")
            add("Lore Swift port", (package / "Package.swift").is_file(), str(package), "python ada_tool.py prepare studio")
    if wasm:
        if ctx.host == "windows":
            ok, output = ctx.probe(["wsl.exe", "--exec", "python3", "--version"])
            add("WSL Python", ok, output, "wsl --install -d Ubuntu-24.04")
            ok, output = ctx.probe(["wsl.exe", "--exec", "sh", "-c", '"$HOME/.local/share/AdaStudio/BuildTools/swift-6.3.2/usr/bin/swift" sdk list'])
            add("WSL WASM SDK", ok and PIN["wasm"]["sdk"] in output.splitlines(), output, "python ada_tool.py prepare wasm")
        else:
            ok, output = ctx.probe([ctx.swift, "sdk", "list"])
            add("WASM SDK", ok and PIN["wasm"]["sdk"] in output.splitlines(), output, "python ada_tool.py prepare wasm")
    if frontend:
        ok, output = ctx.probe(["node", "--version"])
        add("Node.js", ok and node_compatible(output), output + "; minimum " + PIN["node"], "python ada_tool.py prepare playground")
        version = json.loads((ctx.root / "Editor/WebUI/package.json").read_text())["packageManager"].split("@", 1)[1]
        executable = ctx.cache / ("pnpm-" + version) / "node_modules/pnpm/bin/pnpm.cjs"
        add("pnpm", executable.is_file(), f"expected {version}: {executable}", "python ada_tool.py prepare playground")
        panels = Path(args.cloud_panels or ctx.env.get("ADA_CLOUD_PANELS_DIST", ctx.root.parent / "My Projects/adawebsite/dist-panels"))
        add("Cloud panels", all((panels / name).is_file() for name in ("cloud-panel-messages.json", "cloud-panels.js", "style.css")),
            str(panels), "Build adawebsite with npm run build:panels; pass --cloud-panels PATH")
    ok = all(check["ok"] for check in checks if check["required"])
    if args.json:
        print(json.dumps(dict(ok=ok, host=ctx.host, architecture=ctx.arch, checks=checks), indent=2))
    else:
        print(f"AdaEngine doctor: {ctx.host}/{ctx.arch}")
        for check in checks:
            print(f"[{'OK' if check['ok'] else 'MISSING' if check['required'] else 'INFO'}] {check['name']}: {check['detail']}")
            if not check["ok"] and check["fix"]:
                print("  Fix: " + check["fix"])
    return 0 if ok else 1
