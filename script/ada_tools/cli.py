"""Argument parsing and command dispatch for ada_tool.py."""
import argparse
from pathlib import Path
import subprocess
import sys
import urllib.error

from .context import Context, ToolError
from . import environment, studio, web


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def component(value):
    if value not in ("studio", "swift", "tint", "wasm", "playground"):
        raise argparse.ArgumentTypeError("choose studio, swift, tint, wasm or playground")
    return value


def parser():
    # SUPPRESS lets common options appear before or after a subcommand without
    # nested parser defaults discarding the value parsed by its parent.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS, help="Print actions without changing files, installing or building")
    common.add_argument("--swift", default=argparse.SUPPRESS, help="Swift executable (also selects swiftc and nested build tools)")
    common.add_argument("--jobs", type=positive, default=argparse.SUPPRESS, help="Build jobs (default: 2)")
    root = argparse.ArgumentParser(description="AdaEngine toolchains, standalone Studio and web builds (Python 3.9+).", parents=[common])
    commands = root.add_subparsers(dest="command", required=True)
    doctor = commands.add_parser("doctor", parents=[common], help="Check dependencies without installing or downloading anything")
    doctor.add_argument("--profile", choices=("all", "studio", "wasm", "playground"), default="all")
    doctor.add_argument("--json", action="store_true", help="Machine-readable report; exit 1 when required dependencies are missing")
    doctor.add_argument("--cloud-panels", type=Path)
    prepare = commands.add_parser("prepare", parents=[common], help="Install pinned host dependencies; default: studio, wasm and playground")
    prepare.add_argument("components", nargs="*", type=component, metavar="COMPONENT", help="studio, swift, tint, wasm, playground")
    prepare.add_argument("--skip-system", action="store_true", help="Skip apt/brew/winget system prerequisites")

    def build_options(command):
        command.add_argument("--debug", action="store_true", help="Debug configuration (default: release)")
        command.add_argument("--scratch-path", type=Path, help="Isolated build cache (default: .build-tools/ada-tool/<host>/build/<target>)")

    install = commands.add_parser("install", parents=[common], help="Build and install a complete standalone distribution, or copy --source")
    targets = install.add_subparsers(dest="target", required=True)
    app = targets.add_parser("studio", parents=[common], help="Install Studio for the current user")
    build_options(app)
    app.add_argument("--source", type=Path, help="Complete extracted distribution or macOS .app; skips compilation")
    app.add_argument("--destination", type=Path, help="Exact installed application directory (.app on macOS)")
    app.add_argument("--launch", action="store_true")
    app.add_argument("--no-shortcut", action="store_true")
    builder = commands.add_parser("build", parents=[common], help="Build without installing or publishing")
    targets = builder.add_subparsers(dest="target", required=True)
    for target in ("studio", "engine"):
        command = targets.add_parser(target, parents=[common])
        build_options(command)
    command = targets.add_parser("playground", parents=[common], help="Build the existing Studio DOM frontend")
    command.add_argument("--cloud-panels", type=Path, help="adawebsite dist-panels directory")
    command = targets.add_parser("wasm", parents=[common], help="Export release DOM Studio + AdaWebPlayer (WSL on Windows)")
    command.add_argument("--output", type=Path)
    command.add_argument("--scratch-path", type=Path)
    command.add_argument("--ui-dist", type=Path, help="Use an existing built frontend instead of building playground")
    command.add_argument("--cloud-panels", type=Path)
    command.add_argument("--studio-origin", action="append", default=None, help="Allowed Studio origin (repeatable; default: http://127.0.0.1:8080)")
    runner = commands.add_parser("run", parents=[common], help="Open the installed Studio")
    runner.add_argument("target", choices=("studio",))
    runner.add_argument("--debug", action="store_true")
    runner.add_argument("--destination", type=Path)
    preview = commands.add_parser("serve", parents=[common], help="Serve built playground files on loopback; no Cloud backend")
    preview.add_argument("target", choices=("playground", "wasm"))
    preview.add_argument("--directory", type=Path)
    preview.add_argument("--port", type=positive, default=8080)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        ctx = Context(args)
        if args.command == "doctor":
            return environment.doctor(ctx, args)
        if args.command == "prepare":
            environment.prepare(ctx, args)
        elif args.command == "install":
            studio.install(ctx, args)
        elif args.command == "build":
            if args.target == "playground":
                result = web.playground(ctx, args)
            elif args.target == "wasm":
                args.studio_origin = args.studio_origin or ["http://127.0.0.1:8080"]
                result = web.wasm(ctx, args)
            else:
                result = studio.build(ctx, args)
            print(result)
        elif args.command == "run":
            destination = args.destination or studio.default_destination(ctx, args.debug)
            if not ctx.dry:
                studio.validate(destination, ctx.host)
            studio.launch(ctx, destination)
        elif args.command == "serve":
            if args.port > 65535:
                raise ToolError("Port must be between 1 and 65535")
            web.serve(ctx, args)
        return 0
    except (ToolError, OSError, ValueError, subprocess.CalledProcessError, urllib.error.URLError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCancelled", file=sys.stderr)
        return 130
