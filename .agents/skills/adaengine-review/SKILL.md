---
name: adaengine-review
description: Independently review an AdaEngine feature, improvement, or bug fix against its request, accepted design, actual code, and validation evidence. Use in a separate subagent context before task completion and again after fixes.
---

# AdaEngine Independent Review

Operate in a separate context from the implementer. A different model is optional. If independent
subagents are unavailable, report a blocker instead of presenting self-review as independent review.

Read applicable AGENTS instructions, [the knowledge index](../../knowledge/README.md), the original
request, accepted design, implementation plan if present, task boundaries, final diff, and runner report.
Inspect implementation and nearest tests yourself. Resolve APIs and platform behavior from real code.
Run targeted additional checks when existing evidence does not establish a material claim.
Use disposable fixtures or task-owned scratch directories; preserve unrelated work.

Check behavioral completeness, regressions, failure paths, architectural boundaries, Swift isolation
and ownership, ECS access/lifetimes, runtime resource handling, meaningful tests, platform compatibility,
unjustified hardcoding, secrets, and design/documentation freshness. Investigate missing analysis,
empty/skipped suites, ignored warnings, broadened exclusions, and stale or misleading reports.
Read recorded TDD exceptions and approval sources; a local JSON field does not authenticate a human.
For each feature, inspect the delivered user article and navigation, not only its design/ADR or API comments.
Verify instructions/examples match the shipped API and platform/backend support; examine docs/example
checks and applicable offline snapshots. User-facing improvements must update guides; internal-only
explanations must be justified. Missing or inaccurate required user documentation prevents approval.

Do not change production code or approve your own fixes. Give the implementer actionable findings
with severity, location, concrete consequence, and expected behavior. Return implementation defects
for correction. Escalate ambiguous requirements and necessary deviations from the accepted design
to the human; do not silently rewrite the design to match the implementation.

Use `snapshot` immediately before recording the final review. Write a local JSON report under
`.build-tools/contribution/` using this schema:

```json
{
  "reviewer": "independent-subagent-id",
  "context": "separate-context-reference",
  "snapshot": "value-returned-by-the-runner",
  "task_fingerprint": "task_fingerprint-returned-by-the-runner",
  "user_documentation_reviewed": true,
  "verdict": "approved",
  "findings": []
}
```

Use `changes_requested` for implementation findings and `needs_human` for unresolved design decisions.
Never approve while findings remain unresolved or mandatory checks are blocked.
The implementer imports the result with `record-review` and calls `verify --stage done`.
Any subsequent relevant edit requires fresh checks and review of the final state.
