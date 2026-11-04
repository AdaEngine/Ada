# Workflow Commands

Run commands from the repository root. Use a Python 3.11+ interpreter containing the pinned tools from
`script/contribution-requirements.txt`; on Windows that may be
`.build-tools/contribution-tools/Scripts/python.exe`, and on POSIX `.build-tools/contribution-tools/bin/python`.

## Start and Approve

```text
python script/check_contribution.py init --task importer-svg --kind improvement --design Documentation/Designs/image-import.md --files Sources/AdaAssets/SVGSerializer.swift Tests/AdaAssetsTests/SVGSerializerTests.swift
python script/check_contribution.py approve-design --task importer-svg --source "Explicit human approval in the project conversation"
```

The design must exist when approval is recorded. Features also provide `--plan Documentation/Plans/<name>.md`.
Paths are exact repository-relative files, not directories. Include all task-owned files, including new ones.
Initialization preserves the initial unrelated worktree changes. Newly edited paths outside the recorded
scope block progression; inspect them and expand ownership explicitly:

```text
python script/check_contribution.py scope --task importer-svg --files Sources/AdaAssets/ImageImporter.swift
python script/check_contribution.py plan --files Sources/AdaAssets/SVGSerializer.swift
python script/check_contribution.py run --task importer-svg --stage plan
python script/check_contribution.py verify --task importer-svg --stage plan
```

`plan` lists commands without executing them. Local approval records reference a real human action;
writing the record does not create approval. Substantive design changes require renewed approval.

## User Documentation

Before implementation, declare the user-facing article and navigation sources promised in the design:

```text
python script/check_contribution.py documentation --task importer-svg --articles Sources/AdaEngine/AdaEngine.docc/Articles/Developers/ImageDecoders.md --navigation Sources/AdaEngine/AdaEngine.docc/AdaEngine.md
```

The runner requires the article to be new or updated since task initialization and discoverable from
the declared user navigation before Review/Done. Designs, ADRs, agent references and generated `docs/`
cannot count as the article. Include the delivery in the same change as the implementation.
The independent approval must contain `user_documentation_reviewed: true`.

For an improvement with no user-facing impact, use `documentation --task <id> --internal-only-reason
"Explain why public behavior and usage are unchanged"`; the reviewer checks the explanation.
This exemption is unavailable for new features. See [article requirements](user-documentation.md).

## TDD

Pass commands as JSON argv arrays. The following POSIX quoting is illustrative; on PowerShell,
write the array to a UTF-8 JSON file and use `--command-file path.json` instead of `--command-json`.

```text
python script/check_contribution.py tdd --task importer-svg --phase red --command-json '["swift","test","--filter","SVGSerializerTests"]' --test-files Tests/AdaAssetsTests/SVGSerializerTests.swift --expected "Expectation failed" --reason "The importer must reject invalid SVG dimensions"
python script/check_contribution.py tdd --task importer-svg --phase green --command-json '["swift","test","--filter","SVGSerializerTests"]' --test-files Tests/AdaAssetsTests/SVGSerializerTests.swift
python script/check_contribution.py tdd --task importer-svg --phase refactor --command-json '["swift","test","--filter","SVGSerializerTests"]' --test-files Tests/AdaAssetsTests/SVGSerializerTests.swift
```

The Red command must run a test and show the expected behavioral assertion failure. Green/Refactor
use the same command and unchanged tests. Missing tools, compile failures, and empty suites do not qualify.
For justified cases without applicable TDD:

```text
python script/check_contribution.py explain-tdd --task docs-update --reason "Documentation only; no runtime behavior changed"
```

The reviewer must examine the explanation. Do not use it to hide an unavailable required test environment.

## Validate and Review

```text
python script/check_contribution.py run --task importer-svg --stage review
python script/check_contribution.py snapshot --task importer-svg
python script/check_contribution.py record-review --task importer-svg --file .build-tools/contribution/review.json
python script/check_contribution.py verify --task importer-svg --stage done
```

The snapshot command returns JSON containing source and task fingerprints. The separate reviewer uses
both in its report; see [the review skill](../skills/adaengine-review/SKILL.md). Task fingerprints include
scope, approval and TDD evidence. A changed source, task input, tool, or referenced log requires fresh evidence.
Review findings are fixed by the implementer and reviewed again. Design deviations return to the human.

For checks not fully represented by built-in adapters, supply meaningful JSON argv recipes with
`--runtime-command`, `--platform-command`, or `--dependency-command`. These run as real commands
and remain visible in the report. They must cover the relevant runtime/platform/advisory requirements;
an echo command is not a substitute. Missing recipes remain blocked. CLI recipes do not authenticate
remote CI results; their suitability and provenance must be reviewed.

Use `check --files ...` or `check --files-from paths.json` for stateless validation in CI and hooks.
This validates code quality without pretending that CI can authenticate a local interview or chat approval.
Successful `check` does not by itself close a workflow task.

## Hooks and CI

```text
python script/check_contribution.py install-hooks
```

Hook installation is explicit. Existing hooks are backed up and chained, including Git LFS arguments,
stdin, and exit codes. Conflicts stop installation. No global Git settings are changed.
Pre-commit runs quick checks and rejects partially staged/dirty tracked worktrees rather than checking
a different snapshot. Pre-push requires the outgoing branch checked out with a clean worktree and runs
the local publication profile. Fresh complete results are reused only after checking source/tool
fingerprints, exact coverage, commands, and retained logs. After a commit makes evidence stale, previously
successful explicit recipes may be carried forward, but the checks themselves run again.
New branches validate the diff from the merge base with `pre_push.base_ref`
(default `refs/remotes/origin/main`). If that remote-tracking ref or a common ancestor is
unavailable, all tracked files are validated conservatively. No arbitrary HEAD~1 diff is used.

Inspect publication requirements before pushing with `plan --publication --base origin/main`;
`check --publication` runs that profile explicitly. Failed local checks and missing tools without an
approved CI mapping block the push. Configured checks unavailable locally can be `deferred`, with
the mandatory workflow/job shown in the report. Secret scanning and available local checks still run.
CI mappings live in `.agents/validation.json` and must reference existing push/PR jobs.
A publication report never satisfies `verify --stage done`; it is not proof that CI has passed.
The complete `run --stage review` profile stays strict, including missing native/advisory adapters.

Full reports/logs are under `.build-tools/contribution/`; stdout contains compact statuses and paths.
Hooks can be bypassed; use required hosted CI statuses for actual merge blocking. Local validation and
an unpushed workflow file do not prove that server-side rules or remote jobs are enabled.
