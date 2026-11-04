# AdaEngine Contributor Workflow: Agents, Validation, and Independent Review

Status: **Accepted**.
Approval: explicit user approval in the Codex conversation on 2026-11-04.
Date: 2026-11-04.
Scope: development of AdaEngine, its editor, tools, and infrastructure in this repository.
Implementation: **Partial — local implementation; hosted rollout pending**.
See [the implementation plan](../Plans/2026-11-04-ContributorWorkflow.md).

## 1. Problem and Intended Outcome

Human contributors and AI agents must follow the same engineering requirements. Completing a task
requires applicable validation and independent review. Missing tests, unavailable linters,
unverified platforms, and deviations from an accepted design must not result in a claim of completion.

The solution consists of concise entry instructions, workflow skills, a knowledge base, and a shared
validation script. The script performs repeatable checks and saves detailed logs. Agents read a compact
summary and open detailed output when needed. Successful checks do not replace reviewing the code itself.

All design documents must be written in English, including their embedded product requirements and
new architectural decision records. Conversations and interview answers may use the user's language;
the agent incorporates agreed decisions into the English document before requesting approval.

## 2. Change Classification

| Type | Definition | Example |
| --- | --- | --- |
| Feature | A new standalone capability or subsystem | Introducing image importing |
| Improvement | Extending or reworking an existing capability | Adding SVGSerializer to an existing importer; rewriting a serializer |
| Bug fix | Restoring expected behavior | Fixing lost transparency when importing PNG files |
| Maintenance | Updating documentation, tooling, or configuration without adding product behavior | Fixing a link or updating a build command |

Diff size, adding a class, and changing a public API do not independently determine the change type.
When classification is uncertain, the agent asks the human. An improvement still requires validation
proportional to its risk and cannot silently change architectural constraints.

## 3. Stage Transitions

### Features

`Task → Enrich → Design → human approval → Plan → Code → Review → Done`

1. **Task:** capture the request, expected outcome, and initial worktree state.
2. **Enrich:** use the repository's `adaengine-enrich` skill for a structured requirements interview.
   The agent investigates repository facts; the human resolves product and architectural decisions.
3. **Design:** produce an English document covering requirements, boundaries, behavior, decisions,
   and acceptance criteria. Give it to the human to study and wait for explicit approval before proceeding.
4. **Plan:** after approval, prepare an implementation, testing, and platform validation plan.
   Connect requirements to owning subsystems and evidence needed for acceptance.
5. **Code:** use the repository's `adaengine-tdd` skill for testable behavior and invoke validation scripts.
   Implement the user-facing article/update and navigation promised in Design and Plan in the same change.
6. **Review:** a separate subagent independently checks the request, design, code, and validation evidence.
7. **Done:** all mandatory checks pass, findings are resolved, and review covers the final code state.

Additional approval of the implementation plan is unnecessary unless the human explicitly requests it.
Substantive changes to the accepted design return the task to design approval.
Editorial corrections that do not change requirements do not require renewed approval.

### User Documentation Is Part of Delivery

Every new feature must deliver a discoverable user-facing article, or substantially update the relevant
existing article. ADRs, design documents, agent knowledge, API comments, and a changelog entry do not
replace that article. Declare its authored source and navigation during Design/Plan; update them with
the implementation and verify them before independent review and completion.

For example, a ray tracing feature needs a guide explaining its purpose, prerequisites, how to enable it,
a verified minimal example, supported backends/platforms, limitations/fallbacks, and performance tradeoffs.
Document shipped behavior, distinguishing experimental/planned capability explicitly.

Author engine documentation in the relevant `Sources/<Module>/<Module>.docc` catalog; `docs/` is generated
output. Maintain DocC Topics/navigation and applicable Studio offline guides. Use existing article/build
conventions. Improvements affecting user behavior update the relevant guide; a strictly internal
improvement may record an explicit documentation-inapplicability reason for independent review.
New features cannot use that exemption. The reviewer must assess accuracy, discoverability, examples,
and platform claims, not merely file existence. Applicable docs/offline builds remain mandatory evidence.

### Improvements

Use a shorter flow: clarification → design update → explicit human approval → implementation → validation → review.

Every improvement updates the affected subsystem's design. If no design exists, create a concise
description of the current behavior and the proposed change; reconstructing the entire system is unnecessary.
Give the document or substantive design changes to the human and wait for explicit approval before implementation.
Do not create a separate PRD and permanent task plan for every improvement.

### Bug Fixes and Maintenance

Create or update design documents when the task requires it. Fixes within an existing contract do not
need a separate set of PRDs and plans. Reproduction, applicable validation, and independent review remain mandatory.
If fixing a bug requires changing the contract, the human approves the corresponding design change.

Documentation and other changes without testable runtime behavior may record a justified
`not_applicable` result for TDD and runtime tests. Relevant link, structure, configuration, and diff checks still apply.

## 4. Documents, Skills, and Knowledge

| Location | Purpose |
| --- | --- |
| `AGENTS.md` and applicable nested instructions | Mandatory rules, classification, workflow entry points, commands, and links |
| `CONTRIBUTING.md` | The same process for humans: setup, checks, hooks, and reporting results |
| `.agents/skills/adaengine-development/` | Existing engineering guidance and links to subsystem knowledge |
| `.agents/skills/adaengine-feature-flow/` | Feature and improvement stages, approval gates, and skill routing |
| `.agents/skills/adaengine-enrich/` | Repository-local requirements interview and resolution of design decisions |
| `.agents/skills/adaengine-tdd/` | Behavior-driven Red → Green → Refactor cycles and validation evidence |
| `.agents/skills/adaengine-review/` | Independent review of features, improvements, and fixes |
| `.agents/knowledge/` | Architecture, ECS, Swift/concurrency, style, security, platforms, and validation guidance |
| `Documentation/Designs/` | Current subsystem requirements and designs; small PRDs may be included in the design |
| `Documentation/ArchitectureDecisions/` | Existing ADR directory with decisions, rationale, and statuses |
| `Documentation/Plans/` | Durable implementation plans for features where needed |
| `.build-tools/contribution/` | Local reports, logs, and validation state; excluded from Git |

The knowledge base describes the actual code and verified limitations. Cover macOS/iOS and other
supported Apple platforms, Windows, Linux, Android, WASM, Metal, and WebGPU where applicable.
For each platform, distinguish confirmed support, known limitations, and missing validation.
Load detailed guidance for the affected subsystem instead of reading the entire knowledge base for every task.

Reuse existing development-skill references or move them while updating their callers.
Keep each rule, command, and tool version in one maintained source instead of duplicating it.
Resolve tool versions from the active toolchain policy, manifests, and tool configuration.

Code establishes the actual state; accepted design establishes the required state. A discrepancy requires
investigation. Agents must not change the design retroactively to justify an implementation.
Do not rewrite the meaning of accepted ADRs: record a new decision and mark the previous ADR Superseded.
Typographical corrections and factual implementation-status updates are allowed.

### Repository-Local Enrich Skill

The feature flow must use a version-controlled skill in `.agents/skills/`, not depend on a contributor
having the personal `grill-me` or `grilling` skill installed. Provide a self-contained interview workflow
adapted to AdaEngine rather than a wrapper around an unavailable skill or host-specific tool.

The skill maps decisions and their prerequisites, asks currently answerable questions in rounds,
provides recommended answers, and waits for the human before pursuing dependent decisions.
It investigates facts using the repository and available tools; independent exploration may be delegated.
It records settled decisions, scope, constraints, acceptance criteria, and unresolved questions for Design.
It does not implement the feature or treat unanswered questions as approval.

### Repository-Local TDD Skill

Provide a separate `adaengine-tdd` skill and route feature, improvement, and bug-fix work to it when
the task has testable behavior. Use the nearest owning test target and real production paths.
New Swift package tests use Swift Testing; other languages follow their existing test conventions.

Work in small behavior slices:

1. **Red:** write a focused test for the next expected behavior or bug reproduction. Run it through
   the shared validation mechanism and confirm it fails for the expected behavioral reason before changing production code.
2. **Green:** implement the smallest change that satisfies the test and run the same test successfully.
3. **Refactor:** improve the implementation where needed while keeping tests green; run the relevant
   owning suites and any additional checks required by the change's risk.

Do not write the entire implementation before demonstrating Red, manufacture meaningless failures,
or use source-text assertions and mock-only tests as substitutes for material production behavior.
Missing tools and broken dependencies are blockers, not successful Red evidence.
For existing behavior that already passes, identify the missing behavior or explain why a Red cycle is inapplicable.
Record justified exceptions instead of creating artificial tests for prose-only changes.

The skill uses script-generated phase results and logs, tied to the relevant source and test states.
Green after a refactor does not retroactively prove that Red ran before the fix.
The TDD skill does not replace the full validation profile or independent review.

## 5. Shared Validation Script

Proposed entry point: `python script/check_contribution.py`, using Python 3.9+ and the standard library
for orchestration. External tools are invoked explicitly and checked before use.
The existing `ada_tool.py` may delegate to this module later; parallel user work on that CLI
must not be rewritten merely to introduce this workflow.

Proposed interface:

```text
python script/check_contribution.py plan --stage review
python script/check_contribution.py run --stage review
python script/check_contribution.py verify --stage done
python script/check_contribution.py install-hooks
```

`plan` explains selected checks and their reasons without executing them.
`run` executes the checks and returns a compact summary plus paths to logs and a JSON report.
`verify` checks evidence completeness and freshness before a transition.
`install-hooks` explicitly installs supported project hooks while respecting existing Git configuration.
Finalize argument names and the focused TDD phase interface during implementation planning.

Store profiles and rules in one version-controlled configuration, such as `.agents/validation.json`.
Skills, hooks, and CI use the same selection and execution mechanism.

Changed files, dependencies, manifests, tests, build configuration, and task context determine the profile.
A single focused test is insufficient for a change to shared APIs, ECS, macros, or foundational infrastructure.
Changes to validation rules require orchestration tests and independent review as well.

The script does not invoke an LLM to run ordinary commands. It does not modify source files to obtain
a passing result or silently install or upgrade tools.

### Result Semantics

| Status | Meaning | Allows completion |
| --- | --- | --- |
| `passed` | The command executed and its expected outcome was verified | Yes |
| `failed` | The check found a problem | No |
| `blocked` | A required tool, platform, dependency, or other prerequisite is unavailable | No |
| `not_applicable` | An explicit profile rule makes the check irrelevant, with a reason | Yes, if justified during review |

Timeouts, crashes, and missing expected reports are not successes.
A GPU test invocation with execution disabled, or a filter selecting none of the expected tests,
must not produce a passing result. Suppressed output and `--skip` do not remove a check's mandatory status.

### Validation Areas

- **Style:** SwiftLint and applicable existing linters; `git diff --check`; localization when affected.
- **Static analysis:** Swift diagnostics under the project's strict settings and applicable SwiftLint
  analyzer rules. `swiftlint lint` is not `swiftlint analyze`; analysis needs valid compiler evidence
  and a supported environment.
- **Tests:** focused regression/behavior tests, then owning and downstream suites proportional to risk.
  New Swift tests use Swift Testing.
- **Dynamic validation:** exercise the affected UI/runtime, importer, browser export, or service
  according to the profile. Compilation is not a substitute for exercising behavior.
- **Security:** secret detection, changed-dependency analysis, and applicable static/dynamic scenarios
  for untrusted input. Select external analyzers after verifying language and platform support;
  ordinary unit tests must not be presented as a universal DAST/SAST scanner.

Call existing platform and test scripts through adapters instead of duplicating their implementation.
Exclude third-party and generated code only through explicit rules. Expanding exclusions or weakening
checks to obtain a passing result requires review.

The current `.swiftlint.yml` includes only `Sources`; a normal invocation does not establish coverage
for `Tests`, `Editor`, or excluded `Plugins`. Profiles must explicitly define coverage of owned code
in these directories. The build plugin runs lint, not analyzer rules. WebUI currently has no separate
lint/typecheck command, and Python has no configured standalone analyzer. Do not report these as
already executed checks; provisioning and verifying them belongs in the implementation plan.

### Stages and Evidence

Before leaving Enrich, Design, and Plan, check readiness for the next stage: resolved decisions,
the document and human approval, and the validation plan, respectively.
Do not repeat the entire test suite at every document-only stage.

For TDD, retain evidence of the expected failure before the fix and success afterward.
A missing dependency or broken build does not demonstrate reproduction of a behavioral bug.
Explain inapplicability instead of substituting a deliberately meaningless failing test.

Before Code → Review, run the complete applicable validation profile.
Before Review → Done, verify that checks and the review verdict cover the final state.
After fixes, rerun affected checks and review; evidence for an older code state becomes stale.

Reports include the baseline revision/snapshot, task boundaries, fingerprints of relevant files and
configuration, tool versions, commands, results, duration, inapplicability reasons, and log references.
Include uncommitted and new files: checking only `HEAD` does not validate the worktree.
Unrelated user changes do not automatically become part of the task.

Reuse passing results when their inputs and environment are unchanged. Reading an up-to-date report
must not require another full build. Detailed logs remain available; compact summaries must expose
failures and incomplete checks. Do not print secret values or the complete process environment.

## 6. Independent Review

A separate subagent with an independent context performs review. A different model or provider is optional.
Supply the request, accepted design, plan where present, change boundaries, final diff, and validation reports.
The reviewer independently reads implementation and tests, verifies real APIs, and runs additional
targeted checks when needed. The implementer's self-assessment is not independent review.

Review requirements, behavioral completeness, regressions, architectural boundaries, concurrency,
memory/resource handling, platforms, unjustified hardcoding, secrets, accuracy of validation claims,
and documentation freshness.

The reviewer does not edit production code or approve its own fixes. Return implementation defects
to the implementer and review the final version after corrections. Escalate ambiguous requirements
and necessary design deviations to the human. Fixing findings within the accepted design does not
require another product decision.

Verdicts are `approved`, `changes_requested`, or `needs_human`, tied to a code version and concrete
findings with locations, reasons, and verifiable expected behavior.
If no subagent mechanism is available, independent review is blocked; self-review is not a fallback.
Human contributors also need a reproducible way to request agent review. A test runner alone must
not pretend that a separate reviewer exists.

## 7. Git Hooks and CI

The proposed `pre-commit` runs fast staged-content checks: diff validation, applicable lint,
secret detection, and lightweight configuration checks. It does not replace the full task profile.
Partially staged files must be checked using the index snapshot or rejected with an explanation;
checking a different file version does not validate the commit.

`pre-push` runs the applicable complete profile for outgoing changes and reuses fresh local results.
Following the explicit user decision on 2026-11-04, publication uses local checks plus mandatory CI:
checks unavailable locally may be marked `deferred` only when mapped to a real version-controlled
CI job. Failed local checks and missing tools without such a mapping still block publication.
Deferred checks are not successes or inapplicable checks. A publication report cannot satisfy task
completion; full validation and the required CI/platform evidence remain mandatory for Review/Done.
The pre-push report lists the required CI jobs. This does not authenticate their result or configure
server-side branch protection, and a CI job lacking its adapter remains blocked until configured.
Hooks support Windows and POSIX systems and invoke the Python orchestrator.
Installation must preserve existing hooks and `core.hooksPath`, explicitly identifying conflicts.
Checks do not stash, reset, or clean the user's worktree to create a temporary validation state.
The current checkout already has a Git LFS `pre-push` hook. Preserve its execution, arguments, and
input; both LFS and project validation must succeed in the composed hook chain.

CI uses the same rules, retains reports, and validates required platforms. Windows cannot establish
Metal/iOS behavior, and native WebGPU cannot establish browser WASM behavior. An appropriate CI runner
can perform checks unavailable locally; the task remains incomplete until their results arrive.
Changes to shared code require considering every platform supported by that code.

Git hooks are bypassable, so they provide early feedback while CI remains the mandatory barrier.
Actual merge blocking requires an enabled server-side rule for required CI checks. A workflow YAML
alone does not provide branch protection; server configuration is a separate rollout step.

Design acceptance starts by giving the document to the human and obtaining explicit approval.
An agent-written local "approved" record is not independent proof of a human action. Keep a reference
to the approval source; CI can verify approval automatically where the PR process supports it.
Chat approval without a trusted integration remains evidence checked by a human.
Likewise, a JSON report without trusted author identity does not prove reviewer independence.

## 8. Rollout Boundaries

- Update AdaEngine contributor workflows, not the game-authoring skills bundled inside Studio.
- Do not introduce sweeping engine refactors or rewrite the history of existing ADRs.
- Mutation testing and a CRAP threshold are not mandatory gates in this design.
- Preserve user changes to AGENTS.md, README.md, and the in-progress ada_tool CLI.
- Preserve the shared `.build`; use incremental task-owned scratch directories where needed.
- Explain automation limits: scripts cannot prove all requirements correct, authenticate arbitrary
  report authors, or infer human decisions without accessible evidence.

## 9. Implementation Acceptance Criteria

1. Entry instructions and CONTRIBUTING describe the same classification and workflow.
2. A feature cannot proceed to implementation before the human receives and explicitly approves its design.
3. Improvements update the existing design or create a concise one if missing.
4. Repository-local feature-flow, Enrich, TDD, and independent-review skills are available under
   `.agents/skills/`. Enrich works without personal grill-me/grilling installations; TDD supports bug fixes as well.
5. The knowledge base provides navigation and verified subsystem, Swift, and platform guidance.
6. One orchestrator runs real lint, analysis, and tests for agents, hooks, and CI, keeping stdout compact.
7. Orchestrator tests establish that command failure, timeout, missing tools, and stale evidence
   prevent transitions; inapplicability has a reason; an empty test selection cannot produce false success.
8. Profile selection covers root SwiftPM, Editor, WebUI, Python/tooling, and documentation, expanding
   checks for manifests, shared APIs, and platform code.
9. Validate paths containing spaces, Windows/POSIX behavior, staged/unstaged changes, new files,
   and existing-hook conflicts while preserving user files and configuration.
10. Independently review the final changes and demonstrate escalation when design conflicts arise.
11. Explicitly report failed and unperformed platform checks; do not claim completion before resolution.
12. CI invokes the same orchestrator, and the required server-side merge-blocking rule is confirmed.
    If repository changes are ready but that rule is not enabled, report code readiness and incomplete
    rollout separately. The overall process is not deployed until the rule is confirmed.
13. Design documents are English-only, including this document and newly created or substantively updated designs.
14. Exercise Enrich and TDD skills on realistic tasks: unresolved decisions stop progression, and a
    behavioral Red failure is recorded before a production fix, followed by Green and relevant refactor checks.
15. Feature completion is blocked without declared, changed user-facing article sources and valid navigation.
    User-facing improvements update their guides; internal-only improvements provide a reviewed reason.
    Independent approval explicitly confirms user-documentation review. Documentation-only DocC edits
    select documentation checks rather than unrelated engine/GPU builds.

After approval, produce an implementation plan identifying concrete checks, tools, CI jobs, skill
validation scenarios, and the review mechanism available in supported environments. Changes to the
agreed mandatory gates or approval process require returning to the human.
