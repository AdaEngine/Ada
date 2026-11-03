---
name: adaengine-feature-flow
description: Guide AdaEngine features and improvements through requirements, English design, human approval, planning, implementation, scripted validation, and independent review. Use when introducing or extending a capability; fixes within an existing contract use the shorter bug workflow.
---

# AdaEngine Feature Flow

Read [the accepted workflow](../../../Documentation/Designs/contributor-workflow.md) and
[workflow commands](../../knowledge/workflow.md). Resolve links relative to this skill's directory.

## Classify and Enrich

Inspect the repository and preserve existing work. A new subsystem is a feature; extending an existing
one, including adding SVG support to an importer or rewriting a serializer, is an improvement.
Ask the human when classification is uncertain. Present the feature flow when a new feature is detected.

Use [adaengine-enrich](../adaengine-enrich/SKILL.md) to settle requirements and design decisions.
Do not ask the user for facts discoverable from code, tests, configuration, or connected tools.
An improvement may need only a focused clarification rather than a full feature interview.

## Design and Human Approval

Create or update the relevant design under `Documentation/Designs/`, in English. Include scope,
behavior, ownership, important alternatives, constraints, platform impact, and acceptance criteria.
An improvement updates the existing design; create a concise design if one is missing.
Include a user-documentation delivery plan: article source, navigation, verified example and docs checks.
Every feature ships a discoverable user-facing article/update. User-facing improvements update their guides;
an internal-only improvement records a reviewed reason. Follow [user documentation](../../knowledge/user-documentation.md).
Reuse accepted ADRs. New lasting architectural decisions belong in `Documentation/ArchitectureDecisions/`;
supersede changed decisions instead of rewriting their historical meaning.

Give the actual document to the user to study. Wait for their explicit approval before planning or
implementation. Silence, a generated status field, or the agent's own judgment is not approval.
Record the source using `approve-design`; explain that a local record is an attestation, not authentication.

## Plan, Implement, Validate

After approval, create the feature implementation plan under `Documentation/Plans/`. Additional
approval of that plan is required only when the user requests it. Improvements do not need a new
permanent plan for every task. Use [adaengine-development](../adaengine-development/SKILL.md) and
[adaengine-tdd](../adaengine-tdd/SKILL.md) for implementation.
Declare article/navigation paths with `documentation`; implement the guide in the same change as the code.
An ADR, design, changelog or API comment does not satisfy the user-article requirement. Update DocC Topics,
applicable offline guides and example evidence before review. The generated `docs/` site is not an authoring source.

Initialize local task state with the explicitly owned paths. Expand that scope as files are added;
do not include unrelated user changes. Use the runner before moving to the next stage. Do not edit
validation rules, suppress warnings, or delete tests merely to obtain a passing result.
Missing tools and unavailable required platforms block completion; use corresponding CI/hardware evidence.

## Independent Review and Completion

After the full Code → Review validation, invoke [adaengine-review](../adaengine-review/SKILL.md)
in a separate subagent context. A different model is optional. Supply the task, approved design,
plan, boundaries, diff, and validation report. Keep the reviewer independent of implementation.

Fix implementation findings, rerun affected checks, and request review of the final state.
Return substantive design changes or ambiguities to the human. Finish with `verify --stage done`.
Report exact passed checks and remaining blockers. A local success does not establish hosted CI,
branch protection, or behavior on platforms that were not exercised.
