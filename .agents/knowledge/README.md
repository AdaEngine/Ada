# AdaEngine Contributor Knowledge

Read only the sections relevant to the task. Facts come from the checked-out source, manifests,
configuration, and tests; accepted designs define required behavior. Report discrepancies instead
of silently selecting whichever source makes implementation easier.

| Task | Start here |
| --- | --- |
| Classification, approval, TDD evidence, review | [Workflow commands](workflow.md) |
| Module ownership and dependency direction | [Architecture](../skills/adaengine-development/references/architecture.md) |
| Entity storage, queries, scheduling, scripting bridges | [ECS runtime](../skills/adaengine-development/references/ecs-runtime.md) |
| UI identity, event paths, editor packages and real-path testing | [UI and editor](../skills/adaengine-development/references/ui-editor.md) |
| Swift isolation, ownership, style, API design | [Swift engineering](swift.md) |
| Platform constraints and required evidence | [Platforms](platforms.md) |
| Profiles, analysis, tests, and truthful results | [Validation](validation.md) |
| Feature articles, navigation, examples, and documentation checks | [User documentation](user-documentation.md) |
| Untrusted inputs, dependencies, credentials | [Security](security.md) |
| Apple Instruments captures | [Trace analysis](../skills/adaengine-development/references/instruments-trace-analysis.md) |

The linked existing subsystem references remain their maintained source; do not copy them into a
second handbook. Read the nearest `AGENTS.md` before editing. Engine-contributor skills here are
separate from game-authoring skills distributed within Studio.
