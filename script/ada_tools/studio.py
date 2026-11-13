"""Build and install complete standalone Studio distributions."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from .context import ToolError
from .environment import native_dependencies, require_swift, windows_environment


def configuration(args):
    return "debug" if args.debug else "release"


def profiling(args):
    return getattr(args, "profile", False)


def symbol_flags(host):
    """Debug information for an optimized build, in the host profilers' native format."""
    flags = ["-Xswiftc", "-g"]
    if host == "windows":
        # WPA/Superluminal/Visual Studio read CodeView PDBs; lld-link writes them with -debug.
        flags += ["-Xswiftc", "-debug-info-format=codeview", "-Xcc", "-gcodeview", "-Xlinker", "-debug"]
    return flags


def build(ctx, args):
    require_swift(ctx)
    mode = configuration(args)
    label = args.target + ("-profile" if profiling(args) else "")
    scratch = (args.scratch_path or ctx.cache / "build" / label).resolve()
    if ctx.host == "windows":
        windows_environment(ctx)
    if args.target == "studio":
        if ctx.host == "windows" and ctx.arch != "x86_64":
            raise ToolError("Standalone Windows Studio currently supports x86_64 only")
        native_dependencies(ctx)
        ctx.save()
        if ctx.host == "macos":
            ctx.run(["xcodegen", "generate", "--spec", ctx.root / "Editor/project.yml"])
            ctx.run(["xcodebuild", "-project", ctx.root / "Editor/AdaEditor.xcodeproj", "-scheme", "AdaEditor-Standalone",
                     "-configuration", mode.capitalize(), "-destination", "platform=macOS", "-derivedDataPath", scratch,
                     *(["DEBUG_INFORMATION_FORMAT=dwarf-with-dsym"] if profiling(args) else []),
                     "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"], log=ctx.cache / f"{label}-{mode}-build.log")
            app = scratch / "Build/Products" / mode.capitalize() / "Ada Studio.app"
            ctx.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--entitlements",
                     ctx.root / "Editor/Platforms/AdaEditor-Standalone.entitlements", app])
            ctx.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
            return app
    package = ctx.root / "Editor" if args.target == "studio" else ctx.root
    command = [ctx.swift, "build", "--package-path", package, "--scratch-path", scratch, "--configuration", mode]
    if profiling(args):
        command += symbol_flags(ctx.host)
    selection = []
    if args.target == "engine":
        selection = ["--target", "AdaEngine"]
    elif ctx.host == "windows":
        # Building every product also tries WASI-only command plugins on Windows.
        selection = ["--product", "AdaEditor"]
    # Linux packaging also needs gravity-lsp and AdaPackageTool, so build its products together.
    ctx.run([*command, *selection, "--jobs", ctx.jobs], log=ctx.cache / f"{label}-{mode}-build.log")
    output = ctx.run([*command, "--show-bin-path"], capture=True)
    binary = Path(output.splitlines()[-1]) if output else scratch / mode
    if ctx.host == "windows" and args.target == "studio" and not ctx.dry:
        shutil.copy2(Path(ctx.env["LORE_WINDOWS_SDK_PATH"]) / "lore.dll", binary)
    return binary


def distribution(ctx, args, binary, work):
    if ctx.host == "macos":
        return binary
    compiler = ctx.env["ADAENGINE_GRAVITY_PACKAGE_PATH"]
    if ctx.host == "windows":
        path = ctx.helper("package_studio_windows.py", "--bin", binary, "--compiler-root", compiler,
                          "--output", work, "--version", "local-" + configuration(args), "--stage-only",
                          fallback=work / ("AdaStudio-local-" + configuration(args) + "-windows-x86_64"))
    else:
        path = ctx.helper("package_studio_linux.py", "--binary-directory", binary, "--compiler", compiler,
                          "--output", work, "--version", "local-" + configuration(args), fallback=work / "AdaStudio-local-linux")
    return Path(path)


def validate(source, host):
    if host == "macos":
        try:
            with (source / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException) as error:
            raise ToolError("Invalid Studio app: " + str(source)) from error
        executable = info.get("CFBundleExecutable", "")
        if info.get("CFBundleIdentifier") not in ("org.adaengine.editor", "org.adaengine.studio.dev"):
            raise ToolError("Not an Ada Studio application: " + str(source))
        if not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
            raise ToolError("Invalid Studio bundle executable")
        if not os.access(source / "Contents/MacOS" / executable, os.X_OK):
            raise ToolError("Missing app executable in " + str(source))
        return
    files = ["BuildSDK/sdk.json"]
    files += ["AdaEditor.exe", "adastudio.exe"] if host == "windows" else ["AdaEditor", "ada-studio", "adastudio", "lib/liblore.so"]
    for relative in files:
        if not (source / relative).is_file():
            raise ToolError(f"Incomplete Studio distribution: missing {relative} in {source}")
    try:
        json.loads((source / "BuildSDK/sdk.json").read_text(encoding="utf-8"))
    except ValueError as error:
        raise ToolError("Invalid BuildSDK/sdk.json in " + str(source)) from error
    for relative in ("AdaEditor_AdaEditor.resources/Assets", "AdaEngine_AdaRender.resources"):
        if not (source / relative).is_dir():
            raise ToolError(f"Incomplete Studio distribution: missing {relative} in {source}")
    if host == "linux":
        for relative in ("AdaEditor", "ada-studio", "adastudio"):
            if not os.access(source / relative, os.X_OK):
                raise ToolError("Studio executable permission is missing: " + relative)


def variant(debug=False, profile=False):
    """Installed variants live side by side: release, Debug and Profile (release + symbols)."""
    return "Debug" if debug else "Profile" if profile else ""


def default_destination(ctx, debug=False, profile=False):
    name = variant(debug, profile)
    suffix = " " + name if name else ""
    if ctx.host == "macos":
        return Path.home() / "Applications" / ("Ada Studio" + suffix + ".app")
    if ctx.host == "windows":
        return Path(ctx.env.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "Programs" / ("Ada Studio" + suffix)
    return Path(ctx.env.get("XDG_DATA_HOME", Path.home() / ".local/share")) / ("ada-studio-" + name.lower() if name else "ada-studio")


def atomic_install(source, destination, host):
    """Validate, stage and replace only a recognized Studio; roll back on failure."""
    source, requested = Path(source).resolve(), Path(destination).absolute()
    # Check before resolve: do not follow a user-supplied symlink or Windows junction.
    if requested.is_symlink() or (requested.exists() and hasattr(os.path, "isjunction") and os.path.isjunction(requested)):
        raise ToolError("Installation directory must not be a link or junction")
    if requested.exists() and os.name == "nt":
        import stat
        if requested.lstat().st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ToolError("Installation directory must not be a link or junction")
    destination = requested.resolve()
    if destination.parent == destination:
        raise ToolError("Installation directory must not be a filesystem root")
    if source == destination or source in destination.parents or destination in source.parents:
        raise ToolError("Source and destination must be separate, non-overlapping directories")
    validate(source, host)
    if destination.exists():
        validate(destination, host)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Cleanup is restricted to this unique installer-owned sibling, never a supplied path.
    temporary = Path(tempfile.mkdtemp(prefix=".ada-studio-install-", dir=destination.parent))
    staged, backup = temporary / "staged", temporary / "previous"
    try:
        if host == "macos":
            subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
        else:
            shutil.copytree(source, staged, symlinks=True)
        validate(staged, host)
        if destination.exists():
            destination.rename(backup)
        try:
            staged.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if backup.exists():
            print("Previous installation preserved at " + str(backup), file=sys.stderr)
        else:
            shutil.rmtree(temporary)
    return destination


def register(ctx, destination, debug=False, profile=False):
    suffix = variant(debug, profile)
    name = "Ada Studio " + suffix if suffix else "Ada Studio"
    if ctx.host == "windows":
        # Paths are passed via environment, never interpolated into PowerShell code.
        ctx.env["ADA_TOOL_INSTALL_DIRECTORY"] = str(destination)
        ctx.env["ADA_TOOL_SHORTCUT_NAME"] = name
        ctx.run([ctx.which("pwsh") or "powershell.exe", "-NoProfile", "-Command",
                 "$ErrorActionPreference='Stop'; $s=New-Object -ComObject WScript.Shell; "
                 "$p=Join-Path ([Environment]::GetFolderPath('Programs')) ($env:ADA_TOOL_SHORTCUT_NAME+'.lnk'); "
                 "$l=$s.CreateShortcut($p); $l.TargetPath=Join-Path $env:ADA_TOOL_INSTALL_DIRECTORY 'AdaEditor.exe'; "
                 "$l.WorkingDirectory=$env:ADA_TOOL_INSTALL_DIRECTORY; $l.IconLocation=$l.TargetPath+',0'; $l.Save()"])
    elif ctx.host == "macos":
        ctx.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", destination])
    else:
        desktop = Path(ctx.env.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications" / (("ada-studio-" + suffix.lower() if suffix else "ada-studio") + ".desktop")
        if not ctx.dry:
            # Desktop-entry quoting has different escaping rules from a shell.
            executable = str(destination / "ada-studio")
            if any(c in executable for c in ("\n", "\r")):
                raise ToolError("Desktop shortcut paths must not contain newlines")
            escaped = executable.replace("\\", "\\\\\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$").replace("%", "%%")
            desktop.parent.mkdir(parents=True, exist_ok=True)
            desktop.write_text(f'[Desktop Entry]\nType=Application\nName={name}\nExec="{escaped}"\nTerminal=false\nCategories=Development;\n', encoding="utf-8")


def launch_environment(ctx):
    environment = dict(ctx.env)
    # Saved build overrides point into the checkout; an installed app should
    # discover its bundled SDK/tools. Keep overrides explicitly set by the caller.
    for name in ctx.managed:
        if name.startswith(("ADAENGINE_", "ADAEDITOR_", "ADA_MCP_", "LORE_")) and name not in os.environ:
            environment.pop(name, None)
    return environment


def launch(ctx, destination):
    if ctx.host == "macos":
        ctx.run(["open", destination])
    elif ctx.dry:
        print("Launch: " + str(destination), file=sys.stderr)
    else:
        executable = destination / ("AdaEditor.exe" if ctx.host == "windows" else "ada-studio")
        subprocess.Popen([str(executable)], cwd=destination, env=launch_environment(ctx), start_new_session=ctx.host != "windows")


def install(ctx, args):
    destination = (args.destination or default_destination(ctx, args.debug, profiling(args))).absolute()
    if args.source:
        source = args.source.resolve()
        validate(source, ctx.host)
        return install_source(ctx, args, source, destination)
    args.target = "studio"
    binary = build(ctx, args)
    if ctx.dry:
        source = distribution(ctx, args, binary, ctx.cache / "distribution-<unique>")
        return install_source(ctx, args, source, destination)
    ctx.cache.mkdir(parents=True, exist_ok=True)
    # Only this uniquely allocated packaging directory is removed after installation.
    with tempfile.TemporaryDirectory(prefix="distribution-", dir=ctx.cache) as temporary:
        source = distribution(ctx, args, binary, Path(temporary))
        return install_source(ctx, args, source, destination)


def install_source(ctx, args, source, destination):
    # Preserve the Windows installer's existing running-process and transaction checks.
    if ctx.host == "windows":
        extra = ["-SourcePath", source, "-InstallDirectory", destination, "-NoShortcut"]
        ctx.powershell(ctx.root / "script/install_studio_windows.ps1", *extra)
    elif ctx.host == "macos":
        # The legacy entry point fixes the bundle name. Use the Python transaction
        # for the explicit destination, retaining the process check before replacement.
        ok, processes = ctx.probe(["ps", "-axo", "comm="])
        if not ok and not ctx.dry:
            raise ToolError("Cannot check whether Studio is running")
        if any(line.strip().startswith(str(destination.resolve() / "Contents/MacOS") + "/") for line in processes.splitlines()):
            raise ToolError("Close Ada Studio before updating this installation")
        if not ctx.dry:
            atomic_install(source, destination, ctx.host)
    else:
        # /proc reports actual executable locations without requiring pgrep/lsof.
        if not ctx.dry:
            for process in Path("/proc").glob("[0-9]*/exe"):
                try:
                    if process.resolve().is_relative_to(destination.resolve()):
                        raise ToolError("Close Ada Studio before updating this installation")
                except (FileNotFoundError, PermissionError, ProcessLookupError):
                    pass
            atomic_install(source, destination, ctx.host)
    if not args.no_shortcut:
        try:
            register(ctx, destination, args.debug, profiling(args))
        except (OSError, ToolError) as error:
            print("warning: Studio is installed, but application registration failed: " + str(error), file=sys.stderr)
    if args.launch:
        launch(ctx, destination)
    print(("Would install: " if ctx.dry else "Installed: ") + str(destination))
    return destination
