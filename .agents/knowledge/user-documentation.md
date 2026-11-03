# Shipping User Documentation

A feature is delivered with a user-facing article, or a substantial update of the relevant guide,
in the same change as the implementation. An ADR, design, changelog, agent reference, or API comment
does not replace that article. An improvement affecting user behavior updates the affected guide.
Only an internal-only improvement may record a reviewed inapplicability explanation.

## Design and Plan

Specify the article's audience, authored source path, navigation entry, example, and acceptance checks.
Choose the relevant module's `Sources/<Module>/<Module>.docc` catalog and existing writing conventions.
The root `docs/` directory contains generated website output and is not an authoring destination.
Use the existing editor guide sources for editor behavior and human contributor guides for development tooling.

Declare article and navigation paths with the runner's `documentation` command before implementation.
They become task-owned paths. New features cannot declare documentation inapplicable.

## Content and Discoverability

Explain the problem/capability, prerequisites, how to enable/configure/use it, a minimal working example,
observable results, limitations, supported platforms/backends, and performance/compatibility implications.
Scale the depth to the feature. A ray tracing feature, for example, needs its own useful guide covering
activation, supported rendering backends, fallbacks and cost; do not imply planned support already ships.

Verify example APIs against production code and execute/build examples where applicable. DocC generating
HTML does not prove example code compiles or the feature works. Update DocC Topics or an appropriate
user-facing table of contents so readers can find the article. Internal knowledge links alone do not qualify.

## Checks and Review

Before review, the runner requires declared articles to exist, contain content, change from the task's
initial state, and be linked by the declared navigation. DocC-only edits select documentation checks,
not unrelated engine/GPU builds. The existing documentation CI builds DocC; the offline-guide check
verifies the Studio snapshot where applicable. Run the existing generator when those sources change:

```text
python Editor/scripts/update-offline-documentation.py
python Editor/scripts/update-offline-documentation.py --check
```

The generator's maintained input list determines which guides belong to the offline snapshot.
Do not edit its generated catalog by hand. Respect the nearest AGENTS instructions before changing editor files.

The independent reviewer checks accuracy, completeness, navigation, working examples, limitations,
and validation evidence, then records `user_documentation_reviewed: true`. File existence alone does
not establish article quality. Missing applicable DocC/offline/example checks remain explicitly unverified
or blocked; do not claim successful publishing from a local Markdown edit.
