---
name: adaengine-tdd
description: Implement testable AdaEngine behavior and bug fixes in small Red, Green, Refactor cycles using real production paths and script-recorded test evidence. Use during implementation after any required design approval.
---

# AdaEngine TDD

Read [testing and validation](../../knowledge/validation.md) and
[runner commands](../../knowledge/workflow.md). Respect any pending design approval.
New Swift package tests use Swift Testing; Python and JavaScript follow the owning suite's conventions.

Identify one observable behavior and its owning module. Inspect neighboring production code and tests.
Select a focused test command that runs deterministically and selects at least one relevant test.
For a bug, reproduce the actual failure; for new behavior, express the next missing behavior.

## Red

Write the focused test before the production change. Run `tdd --phase red` with the exact argv,
test-file paths, expected failure expression, and a behavioral explanation.
Read the result to establish that the intended assertion failed. Missing dependencies, import/syntax
errors, timeouts, and broken builds are not behavioral Red evidence; resolve the prerequisite first.

Do not introduce deliberate production defects merely to manufacture a Red phase. If an existing test
already covers the behavior, identify the missing scenario or record a justified applicability explanation.
Do not replace real project, filesystem, renderer, UI, or runtime behavior with a source-text check
or mock-only assertion when that production path is material.

## Green

Implement the smallest production change satisfying the test. Run `tdd --phase green` with the same
command and unchanged test content. A passing test after changing its expected result does not complete
the previous cycle; start a new Red cycle if the requirement genuinely changes.
Work in behavior slices rather than writing all tests and the full implementation in separate batches.

## Refactor

Improve the implementation while preserving behavior, then run `tdd --phase refactor` and the relevant
owning/downstream suites. Watch actor isolation, Sendable, ownership, ECS access declarations, allocations,
and platform conditionals. Use the shared runner for lint, analyzers, tests, and applicable runtime checks
before requesting independent review.

For documentation-only changes or cases without testable behavior, record `explain-tdd --reason` and
make the explanation visible to the reviewer. An unavailable test environment is blocked, not inapplicable.
Do not claim historic TDD ordering from a final green run. Bootstrap/external test evidence requires an
explicit explanation and review of the original logs or transcript, not fabricated phase records.
