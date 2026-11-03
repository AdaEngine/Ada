"""Build the existing DOM playground/player and preview static output locally."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

from .context import PIN, ToolError
from .environment import pnpm, require_swift, wsl


def playground(ctx, args):
    if args.cloud_panels:
        ctx.set("ADA_CLOUD_PANELS_DIST", args.cloud_panels.resolve())
    panels = Path(ctx.env.get("ADA_CLOUD_PANELS_DIST", ctx.root.parent / "My Projects/adawebsite/dist-panels"))
    if not ctx.dry and not all((panels / name).is_file() for name in ("cloud-panel-messages.json", "cloud-panels.js", "style.css")):
        raise ToolError("Cloud panels are required: build adawebsite with npm run build:panels, then pass --cloud-panels PATH")
    pnpm(ctx, "install", "--frozen-lockfile")
    pnpm(ctx, "build")
    ctx.save()
    return ctx.root / "Editor/WebUI/dist"


def wasm(ctx, args):
    output = (args.output or ctx.root / "dist/web").resolve()
    ui = args.ui_dist.resolve() if args.ui_dist else playground(ctx, args)
    if ctx.host == "windows":
        def linux_path(path):
            return ctx.run(["wsl.exe", "--exec", "wslpath", "-a", "-u", path], capture=True) or "/mnt/<drive>/" + Path(path).name

        home = ctx.run(["wsl.exe", "--exec", "printenv", "HOME"], capture=True) or "/home/<user>"
        compiler = home + "/.local/share/AdaStudio/BuildTools/swift-6.3.2/usr/bin/swift"
        command = ["build", "wasm", "--swift", compiler, "--output", linux_path(output), "--ui-dist", linux_path(ui), "--jobs", str(ctx.jobs)]
        if args.scratch_path:
            command += ["--scratch-path", linux_path(args.scratch_path)]
        for origin in args.studio_origin:
            command += ["--studio-origin", origin]
        if ctx.dry:
            command.append("--dry-run")
        wsl(ctx, command)
        return output
    require_swift(ctx)
    scratch = (args.scratch_path or ctx.cache / "build/wasm").resolve()
    command = ["--swift", ctx.swift, "--swift-sdk", PIN["wasm"]["sdk"], "--output", output, "--scratch-path", scratch, "--ui-dist", ui]
    for origin in args.studio_origin:
        command += ["--studio-origin", origin]
    ctx.helper("export_studio_web.py", *command, fallback=output)
    return output


class PreviewHandler(SimpleHTTPRequestHandler):
    """Serve a built SPA; APIs require the separate Cloud development services."""
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm"}

    def translate_path(self, path):
        # The frontend's canonical <base> is /studio/, including in a flat dist.
        if not (Path(self.directory) / "studio/index.html").is_file():
            if path.startswith("/studio/"):
                path = path[len("/studio"):]
        return super().translate_path(path)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.startswith("/v1/"):
            self.send_error(503, "Cloud services are not running in static preview")
            return
        nested = (Path(self.directory) / "studio/index.html").is_file()
        if (not Path(self.translate_path(self.path)).exists() or path == "/") and "." not in path.rsplit("/", 1)[-1]:
            self.path = "/studio/index.html" if nested else "/index.html"
        super().do_GET()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def serve(ctx, args):
    directory = (args.directory or ctx.root / ("dist/web" if args.target == "wasm" else "Editor/WebUI/dist")).resolve()
    if not ctx.dry and not any((directory / path).is_file() for path in ("index.html", "studio/index.html")):
        raise ToolError("Missing index.html; run build playground or choose --directory PATH")
    print(f"Static preview: http://127.0.0.1:{args.port}/games (Cloud APIs require separate services)")
    if ctx.dry:
        return
    handler = partial(PreviewHandler, directory=str(directory))
    with ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("\nPreview stopped", file=sys.stderr)
