# Validation and Evidence

Use `python script/check_contribution.py plan` to inspect the selected checks and `run`/`check` to
execute them. See [workflow commands](workflow.md) and the existing
[target/build reference](../skills/adaengine-development/references/validation.md).

Profiles in `.agents/validation.json` select common, Python, root Swift, Editor, WebUI, GPU, platform,
documentation, and workflow checks. Changed manifests/shared code broaden the required profile.
Do not label a missing tool, empty suite, disabled backend, or unsupported host as inapplicable.

| Result | Interpretation |
| --- | --- |
| passed | The real command ran and the expected outcome was established |
| failed | A problem was detected; inspect the linked log |
| blocked | A required prerequisite or evidence is missing |
| not_applicable | The profile explains why the category is irrelevant; reviewer checks the reason |

Install pinned Python tools explicitly with `python -m pip install -r script/contribution-requirements.txt`,
inside a Python 3.11+ venv. The interpreter running the full profile must see those tools.
The runner itself supports Python 3.9 and uses the standard library; it never silently installs analyzers.
Older Python runtimes cannot resolve the fixed versions of several analyzer dependencies. Keep their
core compatibility test separate from the full analyzer environment; do not ignore dependency advisories.

Ruff checks Python lint; Bandit performs Python AST security analysis. Secret detection is offline
and redacts values. Dependency auditing may contact advisory/package services and is not a secret upload.
Each analyzer has limits; no tool proves arbitrary code correct or detects every credential.

SwiftLint lint and analyze are separate. The runner scopes project rules to affected owned Swift files,
including Editor/Tests/Plugins where relevant; it does not inherit a misleading Sources-only coverage claim.
Analyze requires a current compiler log containing the affected compilation commands. An incremental
build without those commands may require a new task-owned scratch path on a supported host.

Focused tests precede owning/downstream suites. UI, asset, rendering, browser, and service changes may
also require a real runtime command. Provide meaningful JSON argv recipes when the default adapter
cannot establish behavior; the reviewer checks that they exercise the relevant production path.
Platform/advisory adapters without a supported recipe remain blocked rather than silently passing.

Reports and logs are ignored local evidence. They include source fingerprints and tool identities;
edits invalidate earlier results. Preserve Red failure logs and Green results. A final green run does
not prove TDD ordering, and a self-authored review report does not establish reviewer independence.
Do not run the engine's full build for documentation/tooling-only work unless its production behavior changes.
