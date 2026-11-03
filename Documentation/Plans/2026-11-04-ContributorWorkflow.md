# Contributor Workflow Implementation Plan

Design: [Accepted contributor workflow](../Designs/contributor-workflow.md).
Approval: explicit user approval in the Codex conversation, 2026-11-04.

## Delivery

1. Implement and test a Python 3.9+ standard-library orchestrator in `script/contribution/`, with
   `script/check_contribution.py` as its entry point. Separate Git snapshots, check selection/execution,
   workflow evidence, and hook handling. Preserve the parallel `ada_tool` work.
2. Start with failing behavioral tests in disposable Git repositories: missing executable, failing and
   timed-out commands, empty test selection, stale evidence, approval changes, TDD ordering, hook
   conflicts, partial staging, and filename handling. Keep test execution deterministic and bounded.
3. Store check profiles in `.agents/validation.json`. Use real Ruff lint, Bandit Python analysis,
   SwiftLint lint/analyze, existing Swift/Editor/WebUI tests, runtime adapters, and secret detection.
   Missing required tools or runtime evidence are blocked. Profiles distinguish host availability
   from applicability; no success is inferred from an empty test filter or a disabled GPU suite.
4. Implement task initialization, design approval references, focused Red/Green runs, review submission,
   compact JSON/log reports, and freshness verification. Approval and reviewer identity limitations
   remain explicit; local attestations are not authenticated human actions.
5. Add repository-local feature-flow, Enrich, TDD, and review skills and a navigable knowledge base.
   Reuse existing subsystem references. Update AGENTS and CONTRIBUTING without replacing unrelated edits.
6. Add opt-in, conflict-aware hooks preserving Git LFS pre-push behavior and standard input. Reject
   partial staging rather than validating the wrong snapshot; never stash/reset/clean user work.
7. Add CI orchestration tests on Windows/macOS/Linux and a stable aggregate validation status.
   Reuse current Swift jobs and provision tools explicitly. Document the server-side required-check
   setup; do not claim branch protection is configured from an unpushed YAML change.
8. Run local Python tests, Ruff, Bandit, secret checks, document/skill validation, and realistic CLI
   smoke tests. Independently forward-test skills and review the final changes with a subagent.

## Verification and Rollout

- Use a task-owned Python 3.11+ `.build-tools/contribution-tools` environment for Python analyzers;
  pin tool dependencies and fixed security-sensitive transitives. The core runner still supports Python 3.9.
- Do not rebuild Swift for Python/documentation-only changes. Run Swift/profile selection tests instead;
  actual Swift/Metal/browser/Android checks remain required when those production paths change.
- Reports live under ignored `.build-tools/contribution/`. Keep successful summaries compact and logs local.
- Preserve all initially modified/untracked files; explicitly scope this task's local validation inputs.
- Record successful local checks and unresolved platform/CI/admin actions separately. Overall rollout
  remains incomplete until hosted CI and the server-side required-check rule are confirmed.

## Implementation Record

- Added the shared runner, explicit task scope/approval/TDD/review evidence, full-profile verification,
  offline secret checks, dependency auditing, and conflict-aware hooks preserving LFS and linked worktrees.
- Added four repository-local skills, contributor knowledge navigation, engineering/platform guidance,
  updated entry instructions and CONTRIBUTING, and the `Contributor validation` CI workflow.
- Independent reviews found and drove regression fixes for scope drift, rename/deletion selection,
  shared-code downstream/platform coverage, invalid Red evidence, stale logs, linked worktrees,
  inferred unittest discovery, retained recipes/cache reuse, and Windows scope normalization.
- Independently forward-tested Enrich/Feature Flow and a real Red → Green → Refactor bug fix in an
  ignored fixture. Bootstrap TDD runs predate the runner's own recording API and retain their original log.
- Python 3.9 compatibility runs without analyzer dependencies; full integration runs in Python 3.12.
  An advisory scan exposed unsupported old transitives on Python 3.9; the analyzer environment was
  upgraded and fixed versions pinned instead of suppressing findings.
- Final local validation and independent review are recorded under ignored `.build-tools/contribution/`.
  No hosted CI run, Metal/browser/device execution, or server-side branch rule is claimed here.

## Remaining Rollout Work

Push/review the repository changes, obtain successful hosted workflow runs on their declared platforms,
and configure required server-side statuses as described in [operations](../ContributorValidation.md).
Provide maintained runtime/platform/advisory recipes for production profiles requiring additional
environments; missing evidence continues to block those tasks. This is an explicit deployment boundary,
not an exemption from validation or a claim of full rollout completion.
