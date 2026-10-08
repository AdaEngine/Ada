---
name: adaengine-development
description: Develop, debug, review, or validate AdaEngine runtime, ECS, rendering, AdaUI, scene, editor, platform, plugin, demo, and package changes in the AdaEngine repository. Use for Swift source changes under Sources, Tests, Editor, Demos, or Plugins and for AdaEngine-specific architecture or build questions.
---

# AdaEngine Development

Use this skill for production work in the AdaEngine repository. Treat the checked-out source, `Package.swift`, the nearest tests, and the repository `AGENTS.md` as the source of truth; documentation and generated projects can lag behind them.

## Start Here

1. Read the repository `AGENTS.md` completely before editing. Check for a more specific `AGENTS.md` in the target subtree.
2. Run `git status --short --branch`. Preserve unrelated edits and untracked files. Do not clean, reset, or rewrite the user's worktree.
3. Identify the actual package boundary:
   - Engine/runtime work uses the root `Package.swift`.
   - AdaEditor is a separate package under `Editor/` and depends on the root package by local path.
   - XcodeGen configuration for the editor lives in `Editor/project.yml`; regenerate the project after changing inputs that it owns.
   - Web export and command/build plugins live under `Plugins/` and are enabled conditionally by the root manifest.
4. Inspect the nearest implementation and tests before choosing an API. Search with `rg` and `rg --files`; do not infer current APIs from old examples.
5. Choose the smallest module that owns the behavior. Avoid adding dependencies to the `AdaEngine` facade when a lower-level target is the correct home.

For Apple Instruments `.trace` captures of AdaEngine or AdaEditor, read [references/instruments-trace-analysis.md](references/instruments-trace-analysis.md) and use the bundled exporter/analyzer instead of manually rewriting XML parsing commands.

For an unfamiliar subsystem or a cross-module change, read [references/architecture.md](references/architecture.md). For ECS, system scheduling, resources, queries, or hot paths, also read [references/ecs-runtime.md](references/ecs-runtime.md). For AdaUI or AdaEditor, read [references/ui-editor.md](references/ui-editor.md). For platform, renderer, WebGPU, or WASM work, read [references/platform-render-web.md](references/platform-render-web.md). Before running validation, read [references/validation.md](references/validation.md).

## Non-Negotiable Engineering Rules

- Use Swift 6.2 language and concurrency semantics unless the checked-out manifest explicitly changes them. The package enables strict memory safety and upcoming `MemberImportVisibility`.
- Keep imports minimal and sorted. Follow `.swiftlint.yml`; in particular avoid force unwraps and broad access-control changes.
- Prefer value types in data-oriented paths. Use reference types for identity or shared ownership only. Avoid allocations, existential churn, and copy-on-write surprises in per-frame ECS/render/UI loops.
- Preserve actor boundaries. UI, application lifecycle, and platform glue normally belong on `@MainActor`; world finalization uses `WorldActor`. Prefer structured concurrency and explicit `Sendable` values.
- Do not use `nonisolated(unsafe)`, `@unchecked Sendable`, detached tasks, or raw-pointer escape hatches without a concrete synchronization or lifetime argument.
- Keep platform code behind existing compile-time conditions. A macOS fix must not silently break Windows, Linux, Android, WASI, iOS, tvOS, or visionOS compilation.
- Do not edit vendored C/C++ trees such as glslang, SPIRV-Cross, libpng, HarfBuzz, miniaudio, box2d, or box3d unless the requested change specifically targets that dependency.
- New package tests under `Tests/` use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), not new XCTest cases.
- Public APIs with non-obvious behavior need doc comments. Prefer additive, source-compatible changes unless the user explicitly requests a breaking redesign.
- Tests must exercise the production path. For editor filesystem, package, SourceKit/LSP, resource, or rendering behavior, use a real temporary project/resource/window when that behavior is material; a mock-only or source-text assertion is not sufficient evidence.

## Implementation Workflow

### Diagnose or review

Trace behavior from its public entry point to the owning subsystem. Confirm the failing state with a focused command or test when practical. Report the cause and evidence; do not implement a fix unless the request includes implementation.

### Change or build

1. Define the behavioral invariant and the owning target.
2. Add or update the nearest focused test when practical.
3. Implement the smallest production-path change; avoid opportunistic refactors.
4. Run the focused test first, then the owning test target, then broader validation proportional to risk.
5. Inspect `git diff --check`, `git diff --stat`, and the final task-owned diff. Confirm `Package.resolved` or generated project changes are intentional.
6. For runtime or UI work, build success alone is not completion when the executable path can be launched or exercised safely.

### Performance-sensitive changes

Establish which path is hot before optimizing. Preserve ECS query/access declarations so the scheduler can reason about read/write conflicts. Prefer chunk/batch operations over one bridge/proxy/allocation per entity. Validate semantics first, then benchmark or profile a realistic workload; do not make universal performance claims from a synthetic micro-test alone.

## Completion Standard

State exactly what changed, which commands passed, and what remains unverified. Distinguish failures caused by the requested diff from pre-existing worktree, dependency, platform, environment, or cache failures. Never describe a generated target, successful compilation, or static source check as proof that an editor app, UI interaction, renderer, or exported web bundle actually works.
