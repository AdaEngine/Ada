"""Rebuild selected renderer modules and Swift Testing into an isolated directory from a compatible Windows build plan.

Useful when SwiftPM resolution is unavailable. Never rewrites the input build cache.
"""
import argparse
import json
from pathlib import Path
import subprocess
import shutil
import yaml


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True, help='Existing SwiftPM scratch directory')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--modules', nargs='+', default=['AdaCorePipelines'])
    parser.add_argument('--link-only', action='store_true', help='Relink already compiled task objects')
    parser.add_argument('--tests-only', action='store_true', help='Reuse task engine modules and recompile tests')
    parser.add_argument('--rebuild-modules', nargs='+', help='Rebuild only these modules from --modules; reuse other task objects')
    parser.add_argument('--reuse-tests', action='store_true')
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    base = options.base.resolve()
    binary = base / 'x86_64-unknown-windows-msvc/debug'
    output = options.output.resolve()
    modules = output / 'Modules'
    modules.mkdir(parents=True, exist_ok=True)
    description = json.loads((binary / 'description.json').read_text())
    commands = {c['moduleName']: c for c in description['swiftCommands'].values() if Path(c['importPath']).name == 'Modules'}

    def compile_module(name, sources, template=None):
        command = commands[template or name]
        snapshot = output / 'Sources' / name
        snapshot.mkdir(parents=True, exist_ok=True)
        stable_sources = []
        for i, source in enumerate(sources):
            source = Path(source)
            destination = snapshot / (str(i) + '-' + source.name)
            destination.write_text('#sourceLocation(file: ' + json.dumps(str(source.resolve())) + ', line: 1)\n'
                                   + source.read_text(encoding='utf-8-sig'), encoding='utf-8')
            stable_sources.append(destination)
        flags = []
        args = iter(command['otherArguments'])
        for flag in args:
            if flag in ('-parseable-output', '-incremental', '-enable-batch-mode'):
                continue
            if flag in ('-index-store-path', '-emit-objc-header-path', '-module-cache-path'):
                value = next(args)
                if flag == '-module-cache-path':
                    flags += [flag, str(output / 'ModuleCache')]
                elif flag == '-emit-objc-header-path':
                    flags += [flag, str(output / (name + '-Swift.h'))]
                continue
            flags.append(flag)
        obj = output / (name + '.o')
        invocation = [command['executable'], '-module-name', name, '-c', *map(str, stable_sources),
                      '-o', str(obj), '-emit-module', '-emit-module-path', str(modules / (name + '.swiftmodule')),
                      '-I', str(modules), '-I', command['importPath'],
                      *flags, '-whole-module-optimization', '-num-threads', '0']
        print('Compiling', name, len(sources), 'sources', flush=True)
        subprocess.run(invocation, check=True)
        return obj

    objects = []
    for name in options.modules:
        sources = [Path(s) for s in commands[name]['sources']]
        known = {str(p.resolve()).casefold() for p in sources}
        sources += [p for p in sorted((root / 'Sources' / name).rglob('*.swift'))
                    if '.docc' not in str(p) and str(p.resolve()).casefold() not in known]
        reuse = options.link_only or options.tests_only or (options.rebuild_modules is not None and name not in options.rebuild_modules)
        objects.append(output / (name + '.o') if reuse else compile_module(name, sources))
    tests = [Path(p) for p in commands['RenderingValidationTests']['sources']]
    for i, path in enumerate(tests):
        original = next((root / 'Tests').rglob(path.name), None)
        if original is not None:
            tests[i] = original
    tests.append(root / 'Tests/AdaEngineTests/Render3DPathTracingTests.swift')
    objects.append(output / 'RenderingValidationTests.o' if options.link_only or options.reuse_tests else compile_module('RenderingValidationTests', list(dict.fromkeys(tests))))
    runner = output / 'runner.swift'
    runner.write_text('import Testing\n@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }\n')
    objects.append(output / 'RenderingValidationPackageTests.o' if options.link_only or options.reuse_tests else compile_module('RenderingValidationPackageTests', [runner], 'RenderingValidationTests'))
    plan = yaml.load((base / 'debug.yaml').read_text(), Loader=yaml.CSafeLoader)
    link = next(c['args'].copy() for c in plan['commands'].values()
                if isinstance(c.get('args'), list) and '-emit-executable' in c['args']
                and any(a.endswith('RenderingValidationPackageTests.xctest') for a in c['args']))
    original = Path(next(a[1:] for a in link if a.startswith('@')))
    excluded = set(options.modules + ['RenderingValidationTests', 'RenderingValidationPackageDiscoveredTests', 'RenderingValidationPackageTests'])
    for line in original.read_text().splitlines():
        path = Path(line.strip('"'))
        target = next((p[:-6] for p in path.parts if p.endswith('.build')), '')
        if target not in excluded:
            objects.append(path)
    filelist = output / 'Objects.LinkFileList'
    filelist.write_text('\n'.join('"' + str(p) + '"' for p in objects) + '\n')
    link[link.index('-o')+1] = str(output / 'RenderingValidation.exe')
    link = ['@' + str(filelist) if a.startswith('@') else a for a in link]
    dawn = next(p for p in (base / 'artifacts').rglob('webgpu_dawn.lib') if 'windows_x86_64_release' in str(p))
    link += ['-L', str(dawn.parent)]
    subprocess.run(link, check=True)
    for name in ['dxcompiler.dll', 'dxil.dll', 'd3dcompiler_47.dll', 'nvngx_dlss.dll']:
        source = binary / name
        if source.is_file():
            shutil.copy2(source, output / name)
    for name in ['AdaCorePipelines', 'AdaRender']:
        shutil.copytree(root / 'Sources' / name / 'Assets', output / ('AdaEngine_' + name + '.resources'), dirs_exist_ok=True)
    print(output / 'RenderingValidation.exe', flush=True)


if __name__ == '__main__':
    main()
