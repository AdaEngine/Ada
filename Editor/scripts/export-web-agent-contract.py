#!/usr/bin/env python3
"""Export native agent references without launching Studio or modifying a project.

Build AdaEditor with the current source first, then pass that executable with
--studio. Normal frontend builds consume the checked-in snapshot; --check verifies
that its source fingerprint is current without a Swift installation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

EDITOR = Path(__file__).resolve().parents[1]
ROOT = EDITOR.parent
OUTPUT = EDITOR / 'WebUI/assets/agent-contract.json'


def sources():
    paths = [
        'Editor/Sources/AdaEditor/Agent/EditorAgentWebContract.swift',
        'Editor/Sources/AdaEditor/Agent/EditorAgentKnowledge.swift',
        'Editor/Sources/AdaEditor/Agent/EditorAgentBundledExamples.swift',
        'Editor/StudioCore/Sources/AdaStudioCore/StudioScene.swift',
        'Tools/AdaWebPlayer/PlayerSceneComponents.swift',
        'Tools/AdaWebPlayer/PlayerScene.swift',
        'Tools/AdaWebPlayer/PlayerAgentBridge.swift', 'Tools/AdaWebPlayer/AdaWebPlayer.swift',
        'Tools/AdaWebPlayer/PlayerGameInput.swift',
        'Sources/AdaInput/InputAction.swift', 'Sources/AdaInput/InputKeyCodes.swift',
        'Sources/AdaInput/GamepadButtons.swift', 'Sources/AdaInput/GamepadAxes.swift',
        'Sources/AdaScriptCompilerCore/AdaScriptAPICatalog.swift',
        'Sources/AdaScriptCompilerCore/AdaScriptAnalysisModels.swift',
    ]
    paths += [path.relative_to(ROOT).as_posix() for path in
              (EDITOR / 'Sources/AdaEditor').glob('Editor*Descriptor*.swift')]
    paths += ['Editor/Sources/AdaEditor/EditorComponentRegistry.swift']
    paths += ['Editor/Sources/AdaEditor/EditorComponentFieldCoding.swift',
              'Editor/Sources/AdaEditor/EditorSceneModel.swift']
    # Codable payloads and nested value types can change outside the inspector
    # descriptor. Invalidate the snapshot rather than silently keeping old shapes.
    for module in ['AdaInput', 'AdaScriptCompilerCore', 'AdaScripting', 'AdaTransform', 'AdaSprite',
                   'AdaScene', 'AdaRender', 'AdaCorePipelines', 'AdaAudio', 'AdaPhysics', 'Math', 'AdaTilemap']:
        paths += [path.relative_to(ROOT).as_posix() for path in
                  (ROOT / 'Sources' / module).rglob('*.swift')]
    paths += [path.relative_to(ROOT).as_posix() for path in
              (EDITOR / 'Sources/AdaEditor/Assets/Examples').rglob('*') if path.is_file() and path.name != '.DS_Store']
    return sorted(set(paths))


def fingerprints():
    return {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
            for path in sources()}


def validate(value):
    if value.get('version') != 1 or value.get('runtimeAPI') != 4:
        raise ValueError('Unsupported native agent contract version')
    components = value.get('components', [])
    names = [component['typeName'] for component in components]
    if not names or len(set(names)) != len(names):
        raise ValueError('Missing or duplicate native component schemas')
    if not value.get('input', {}).get('bindings') or not value.get('api', {}).get('types'):
        raise ValueError('Missing input or API references')
    if not value.get('examples'):
        raise ValueError('Missing native example projects')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--studio', type=Path)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = fingerprints()
    if args.check:
        value = json.loads(args.output.read_text())
        validate(value)
        if value.get('sourceHashes') != expected:
            raise SystemExit('Native agent contract is stale; rebuild Studio and run scripts/export-web-agent-contract.py --studio <AdaEditor>')
    else:
        if not args.studio:
            parser.error('--studio is required for export')
        studio = args.studio.resolve(strict=True)
        # Player-only Swift files are fingerprinted protocol inputs, not linked
        # into the native exporter. SwiftPM correctly does not relink Studio
        # when only those files change; their own WASM build is checked separately.
        compiled = [path for path in expected if not path.startswith('Tools/AdaWebPlayer/')]
        if any((ROOT / path).stat().st_mtime > studio.stat().st_mtime for path in compiled):
            raise SystemExit('Studio executable predates contract sources; rebuild it before export')
        with tempfile.TemporaryDirectory(prefix='ada-agent-contract-') as directory:
            raw = Path(directory) / 'native.json'
            subprocess.run([str(studio), '--ada-studio-cli', 'agent-resources',
                            '--output', str(raw), '--format', 'json'], check=True, cwd=EDITOR)
            value = json.loads(raw.read_text())
        validate(value)
        if fingerprints() != expected:
            raise SystemExit('Contract sources changed during export; rebuild and retry')
        value['sourceHashes'] = expected
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=args.output.parent, delete=False,
                                         prefix='.agent-contract-', encoding='utf-8') as file:
            temporary = Path(file.name)
            json.dump(value, file, ensure_ascii=False, indent=2, sort_keys=True)
            file.write('\n')
        try:
            temporary.replace(args.output)
        finally:
            temporary.unlink(missing_ok=True)
    print(f'Native agent contract verified: {len(value["components"])} components, '
          f'{len(value["input"]["bindings"])} input bindings, {len(value["api"]["types"])} API types')


if __name__ == '__main__':
    main()
