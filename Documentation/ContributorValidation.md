# Contributor Validation Operations

Start with [the contributor workflow](Designs/contributor-workflow.md),
[the command guide](../.agents/knowledge/workflow.md), and [validation guidance](../.agents/knowledge/validation.md).

## Local Installation

Create a virtual environment, install `script/contribution-requirements.txt`, and run the entry point
with that interpreter. `install-hooks` opts into repository-local hooks and preserves existing hooks.
No global Git configuration is changed, and the runner never installs tools implicitly.

Existing hooks are saved as `<hook>.ada-original`. To uninstall, inspect the generated marker,
restore that hook from its saved original, or remove only the generated hook if no original existed.
Never remove unrelated hooks. A backup conflict requires manual reconciliation before installation.

## CI and Required Checks

User-facing documentation delivery is required by the workflow below and reviewed before task completion.

The `Contributor validation` workflow tests orchestration on Windows, macOS, Linux, and the minimum
Python version. Its quality job selects checks from actual changed paths and runs the same orchestrator.
The aggregate status is **Contributor gate**. Existing Swift macOS/Windows workflows remain in place.

After pushing and confirming the workflows, a repository administrator must configure the main/develop
branch ruleset to require **Contributor gate** and the applicable existing Swift test statuses before merge.
Check the exact status names produced by the hosted jobs. Keep required checks stable; do not use
path-filtered workflow triggers that leave a required status permanently absent.

Changing a workflow file locally does not enable required checks. Record hosted run URLs and the confirmed
server rule before claiming complete rollout. This checkout does not authenticate that server setting.

## Profiles Requiring Additional Environments

Shared/platform changes, runtime-sensitive behavior, and unsupported dependency manifests may need
explicit validation recipes. The runner reports these as blocked until a meaningful command is supplied.
The default CI job must remain non-successful when it lacks required platform, browser, Cloud-panel,
or advisory evidence. A missing prerequisite is not an exemption.

Add maintained recipes to the project configuration/CI when their environment becomes available;
use real existing platform scripts and dedicated hardware/CI runners. Do not substitute `echo`, a
different OS, cached shader output, or compilation alone for the required behavior.
Review recipe changes like production code. A wrapper that imports remote results must validate the
run revision, required jobs, outcome, and trusted origin; a caller-provided success string is insufficient.

## Delivering User Documentation

Every new feature ships a user-facing article or a substantial update of its relevant guide in the
same change. Describe how to enable/use the capability, a working example, actual platform/backend
support, limitations and material performance costs. Update navigation so users can find it.
For example, a ray tracing feature needs an article covering activation, supported backends and fallbacks.
Do not substitute design/ADR files, a changelog entry or agent knowledge for the user guide.

Declare planned authoring and navigation paths before implementation:

```text
python script/check_contribution.py documentation --task rendering-feature --articles Sources/AdaRender/AdaRender.docc/RayTracing.md --navigation Sources/AdaRender/AdaRender.docc/AdaRender.md
```

The example names a future task; it does not claim ray tracing is currently implemented. Use actual
catalogs and verified APIs. `docs/` is generated output, so edit authored DocC/user-guide sources instead.
The runner checks delivery before Review/Done and requires explicit documentation confirmation in the
independent approval. The reviewer checks meaning, examples and discoverability, not just file existence.

Improvements affecting user behavior update the relevant guide. An internal-only improvement may use
`documentation --task <id> --internal-only-reason "Public behavior is unchanged; explain why"`.
This exception is reviewer-visible and cannot be used for a new feature.
Run the relevant docs/example/offline checks; the existing docs workflow builds DocC on its supported host.

## Trust and Reports

Local task/approval/review JSON files are operational attestations. They do not independently prove
human identity, independent context, historical TDD ordering, or arbitrary remote job results.
Use the actual conversation/PR approval and separate reviewer context as evidence, and keep those
limitations visible in review. Referenced logs and snapshots are checked for freshness and completeness.
