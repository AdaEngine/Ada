#!/usr/bin/env python3
"""Build the editor's offline guide snapshot from repository documentation."""
import argparse
import json
from pathlib import Path
import re

EDITOR = Path(__file__).resolve().parents[1]
ROOT = EDITOR.parent
OUTPUT = EDITOR / 'Sources/AdaEditor/Assets/Documentation/catalog.json'


def articles():
    sources = [(EDITOR / 'Documentation/EditorGuide.md', 'Editor')]
    for module, section in [('AdaEngine', 'AdaEngine'), ('AdaScripting', 'AdaScript')]:
        catalog = ROOT / f'Sources/{module}/{module}.docc'
        sources += [(path, section) for path in sorted(catalog.rglob('*.md'))
                    if path.stem not in {'HowToBuildEngine', 'MakeTutorials'}]
    order = ['EditorGuide', 'AdaEngine', 'Building', 'AdaUIIdentity', 'VisionOSWindowed',
             'SPMDebug', 'Contributing', 'AdaScripting', 'GettingStartedWithAdaScript',
             'AdaScriptLanguage', 'AdaScriptECS', 'AdaScriptDiagnosticsAndPerformance']
    sources.sort(key=lambda entry: order.index(entry[0].stem) if entry[0].stem in order else len(order))
    titles = {path.stem: re.sub(r'`', '', path.read_text().splitlines()[0].removeprefix('# '))
              .replace('Ada Script', 'AdaScript') for path, _ in sources}
    titles['AdaScripting'] = 'AdaScript'
    result = []
    for path, section in sources:
        text = path.read_text()
        blocks, pending, code, language = [], [], None, ''

        def flush():
            if not pending:
                return
            value = '\n'.join(pending).replace('Ada Script', 'AdaScript')
            pending.clear()
            links = []

            def doc_link(match):
                target = match[1]
                if target not in titles:
                    raise ValueError(f'Unresolved documentation link: {target} in {path}')
                links.append({'title': titles[target], 'destination': target})
                return titles[target]

            def web_link(match):
                links.append({'title': match[1], 'destination': match[2]})
                return match[1]

            value = re.sub(r'<doc:([^>]+)>', doc_link, value)
            value = re.sub(r'\[([^\]]+)\]\((https?://[^)]+)\)', web_link, value)
            value = re.sub(r'<(https?://[^>]+)>', lambda m: web_link(['', m[1], m[1]]), value)
            value = re.sub(r'``([^`]+)``', r'`\1`', value)
            value = re.sub(r'(?m)^- ', '• ', value)
            value = re.sub(r'(?m)^(\d+)\. ', r'\1\\. ', value)
            heading = re.match(r'^(#{1,6}) (.*)$', value)
            blocks.append({'kind': 'heading' if heading else 'text',
                           'text': heading[2] if heading else value,
                           'level': len(heading[1]) if heading else 0, 'links': links})

        # DocC metadata is presentation configuration, not article text.
        text = re.sub(r'(?m)^@Metadata \{\n.*?^\}\n', '', text, flags=re.S)
        text = re.sub(r'<!--.*?-->', '', text, flags=re.S)
        for line in text.splitlines()[1:]:
            if line.startswith('```'):
                if code is None:
                    flush()
                    code, language = [], line[3:].strip()
                else:
                    blocks.append({'kind': 'code', 'text': '\n'.join(code), 'language': language, 'links': []})
                    code = None
            elif code is not None:
                code.append(line)
            elif not line.strip():
                flush()
            elif line.startswith('#'):
                flush()
                pending.append(line)
                flush()
            else:
                pending.append(line)
        if code is not None:
            raise ValueError(f'Unclosed code fence: {path}')
        flush()
        result.append({'id': path.stem, 'title': titles[path.stem], 'section': section,
                       'source': str(path.relative_to(ROOT)), 'blocks': blocks})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Fail when bundled guides need regeneration')
    args = parser.parse_args()
    data = json.dumps(articles(), ensure_ascii=False, indent=2) + '\n'
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != data:
            raise SystemExit('Offline documentation is stale. Run python3 scripts/update-offline-documentation.py')
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(data)
    print(f'{len(json.loads(data))} offline guides verified' if args.check else f'Updated {OUTPUT}')


if __name__ == '__main__':
    main()
