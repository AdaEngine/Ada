---
name: adaengine-enrich
description: Interview a contributor to resolve requirements and design decisions for an AdaEngine feature or improvement before writing its design. Use for unclear behavior, constraints, scope, or acceptance criteria; investigate repository facts independently.
---

# AdaEngine Enrich

Sharpen the request into decisions that can support an implementable English design.
This skill is self-contained; personal grill-me/grilling installations are unnecessary.

Read [the knowledge index](../../knowledge/README.md), applicable AGENTS instructions, and the
nearest implementation/design before asking factual questions. Use current code to establish what
exists and accepted designs to establish what is required. Investigate discrepancies explicitly.

Map unresolved decisions and their prerequisites. Ask independent, currently answerable questions
in a round; leave dependent questions until their prerequisites are settled. Give each question
a short title, numbered identifier, concrete choices when useful, and a recommended answer.
Word recommendations so an affirmative answer has an unambiguous meaning.

The human decides product behavior, scope, and architectural tradeoffs. The agent finds facts.
Use repository searches and tools for facts; delegate independent exploration to a fresh-context
subagent when available. Continue independent questions while that investigation runs.
Do not ask about an installed tool, existing API, file location, or current behavior that can be inspected.

After each round, incorporate corrections and accepted recommendations, then recompute the remaining
decisions. Do not silently reinterpret examples: adding SVGSerializer to an existing importer is
an improvement in this repository, even if it introduces a public type or input format.

Capture purpose, scope, expected behavior, edge cases, owning modules, platform expectations,
compatibility/security/performance constraints, and observable acceptance criteria as they become relevant.
Resolve the user-documentation audience, article location, discoverability, usage example and limitations
needed to explain the feature. Include those deliverables in Design; do not defer them indefinitely after coding.
Avoid asking routine implementation choices that the agent can resolve within the agreed requirements.
When decisions are settled, summarize the agreement and produce the English design through
[adaengine-feature-flow](../adaengine-feature-flow/SKILL.md).

An interview answer is not approval of a design the user has not received. Give the resulting document
to the user and wait for explicit approval before advancing. Do not start implementation during Enrich.
