# External design skill provenance

- Source: [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).
- Revision: [`b7d5353e0130feb8c5574ef1251f8a1db1873ccb`](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill/tree/b7d5353e0130feb8c5574ef1251f8a1db1873ccb).
- Imported on: 2026-11-05.
- Source directories: `.claude/skills/{banner-design,brand,design-system,design,slides,ui-styling,ui-ux-pro-max}`.
- Destination: the corresponding directories under `.agents/skills/`, including bundled scripts,
  data, references, templates, tests, and fixtures. No global skill or package installation is required.
- License: upstream MIT license copied into each imported skill's `LICENSE`.

## Local integration

The root [Studio design rules](../../AGENTS.md#ada-studio-visual-design-rules) and
[local Studio workflow](adaengine-studio-design/SKILL.md) govern Ada Studio work.
Generic style suggestions, icon-family preferences, token output paths, and stack examples in the
external bundle must be reconciled with the existing Studio theme, Material Icons/Symbols,
platform implementation, and accepted design. Only load skills relevant to the current request.

The core `ui-ux-pro-max/SKILL.md` command examples use `.agents/skills/ui-ux-pro-max/` instead
of the upstream Claude plugin variable; resolve them from the repository root or use an absolute
path to the installed skill. Other skills already resolve their scripts relative to their own
skill directory. No upstream runtime script/data changes are made by this integration.
The other six entrypoints retain their Claude `argument-hint` as a nested `metadata` field
instead of a top-level frontmatter key, so they validate as Codex skills.

Optional generation helpers can require third-party Python packages, provider credentials, or
network services. Importing the bundle does not configure or invoke those services. The main
UI/UX search uses only Python's standard library and bundled data.

Some upstream tests validate the upstream repository's publishing/catalog tooling and expect
files outside the shipped skill directories (`scripts/`, `src/`, and `cli/`). Those tests retain
their original contracts; running them requires a checkout of the pinned upstream repository.
Do not present those integration checks as passed by standalone skill smoke tests.

## Validation limits of this import

The local skill entrypoints pass the Codex skill format validator, and the core offline search,
design-system query, and data-contract validator run successfully. These checks do not establish
that every optional generator or upstream maintenance test works in AdaEngine.

The complete AdaEngine contribution check currently fails on the unmodified upstream bundle:
trailing whitespace, Ruff findings, sample credentials/catalog hashes flagged by secret scanning,
a Bandit finding for controlled XML parsing inside an icon test, and test-runner compatibility.
Several suites require pytest, while AdaEngine's default Python adapter invokes unittest;
other suites require the upstream checkout described above. The dependency advisory check
also requires a supplied analysis command. No exceptions, suppressions, test removals, or
validation configuration changes are included in this import. Full validation remains blocked
until those integration issues are resolved; the import must not be described as fully validated.

## Updating

Select and record an explicit upstream revision. Review changes before replacing the vendored
files, preserve the local path adaptation and license copies, and rerun the affected offline
searches and tests. Keep the root skill catalog aligned with the actual installed skills.
