#!/usr/bin/env python3
"""Export the DOM Studio and the fixed AdaPlayer using the existing WASM command plugin.

Run on Linux/macOS with Swift 6.3.2 + its WASM SDK (on Windows, use WSL).
The outputs are static files; this command never deploys or enables hosted AI.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def prepare(editor, player, origins, legacy=False, ui_dist=None):
    editor.mkdir(parents=True, exist_ok=True)
    if legacy:
        source = ROOT / 'Editor/Web/Sources/AdaEditorWeb/Resources/studio-browser.js'
        shutil.copy2(source, editor / 'studio-browser.js')
        (editor / 'studio-entry.js').write_text("import './studio-browser.js';\nawait import('./main.js');\n", encoding='utf-8')
        html = (editor / 'index.html').read_text(encoding='utf-8')
        html = html.replace('src="./main.js"', 'src="./studio-entry.js"')
        if './studio-entry.js' not in html:
            raise RuntimeError('Exporter entrypoint changed; cannot install Studio browser integration')
        (editor / 'index.html').write_text(html, encoding='utf-8')
    if not (player / 'AdaWebPlayer.wasm').is_file():
        raise RuntimeError('Missing fixed player export')
    for name in ('studio-player.js', 'studio-editor.js', 'studio-editor-math.js', 'studio-bootstrap.js'):
        shutil.copy2(ROOT / 'Plugins/AdaWebExportPlugin/Runtime' / name, player / name)
    html = (player / 'index.html').read_text(encoding='utf-8')
    html = re.sub(r'<script type="module" src="\./(?:player-lobby|main)\.js"></script>', '<script type="module" src="./studio-player.js"></script>', html)
    if './studio-player.js' not in html:
        raise RuntimeError('Exporter player entrypoint changed')
    html = html.replace('<script type="module" src="./studio-player.js"></script>', '<script src="./studio-bootstrap.js"></script>\n  <script type="module" src="./studio-player.js"></script>')
    (player / 'studio-preview.html').write_text(html, encoding='utf-8')
    (player / 'studio-player-config.json').write_text(json.dumps({'allowedOrigins': origins}), encoding='utf-8')
    if not legacy:
        from prepare_studio_frontend import prepare as prepare_frontend
        prepare_frontend(editor.parent, ui_dist)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift', default='swift')
    parser.add_argument('--swift-sdk', default='swift-6.3.2-RELEASE_wasm')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--scratch-path', type=Path, default=Path('/tmp/ada-studio-export'))
    parser.add_argument('--studio-origin', action='append', required=True)
    parser.add_argument('--prepare-only', action='store_true', help='Install browser entrypoints into existing exports')
    parser.add_argument('--ui-dist', type=Path, default=ROOT / 'Editor/WebUI/dist')
    parser.add_argument('--legacy-wasm-editor', action='store_true', help='Export the older AdaUI/WASM editor instead of the DOM shell')
    args = parser.parse_args()
    if not args.legacy_wasm_editor and not (args.ui_dist / 'studio.js').is_file():
        parser.error('Build Editor/WebUI first: pnpm install && pnpm build')
    from urllib.parse import urlparse
    for origin in args.studio_origin:
        value = urlparse(origin)
        local = value.scheme == 'http' and value.hostname in ('localhost', '127.0.0.1', '::1')
        if (value.scheme != 'https' and not local) or not value.netloc or value.path not in ('', '/') or value.username or value.query or value.fragment:
            parser.error('--studio-origin must be an HTTPS origin (HTTP is allowed only for loopback development)')
    output = args.output.resolve()
    editor, player = output / 'studio', output / 'player'
    if not args.prepare_only:
        env = dict(os.environ, ADAENGINE_WEB_EXPORT='1', BUILD_WASM='1')
        compiler = shutil.which(args.swift)
        if compiler:
            # The export plugin invokes `swift` itself; keep it on the requested toolchain.
            env['PATH'] = str(Path(compiler).resolve().parent) + os.pathsep + env.get('PATH', '')
        if 'ADAENGINE_YAMS_PACKAGE_PATH' not in env:
            from ensure_wasi_yams import prepare as prepare_yams
            # Keep the package identity "yams" so transitive dependencies use the same local override.
            env['ADAENGINE_YAMS_PACKAGE_PATH'] = str(prepare_yams(args.scratch_path.resolve() / 'wasi-dependencies' / 'Yams'))
        products = [('AdaWebPlayer', ROOT, player)]
        if args.legacy_wasm_editor:
            products.insert(0, ('AdaEditorWeb', ROOT / 'Editor/Web', editor))
        for product, package, destination in products:
            cache = args.scratch_path.resolve() / product
            command = [args.swift, 'package', '--package-path', str(package), '--scratch-path', str(cache / 'host'), '--disable-sandbox',
                       '--allow-writing-to-package-directory', '--allow-network-connections', 'all', 'export-web', '--product', product,
                       '--output', str(destination), '--scratch-path', str(cache / 'wasm'), '--swift-sdk', args.swift_sdk, '--release']
            subprocess.run(command, cwd=ROOT, env=env, check=True)
    prepare(editor, player, [origin.rstrip('/') for origin in args.studio_origin], args.legacy_wasm_editor, args.ui_dist)
    print('Editor: ' + str(editor))
    print('Fixed player: ' + str(player))


if __name__ == '__main__':
    main()
