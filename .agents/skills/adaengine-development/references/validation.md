# Build and Validation

Read this reference before running builds or tests. Select the smallest command that proves the changed behavior, then broaden based on risk.

## Root Package

```bash
swift build
swift test --filter SomeSuiteName
swift test --parallel --filter AdaECSTests
swift test --parallel
```

Root test targets mirror modules, including `AdaEngineTests`, `AdaECSTests`, `AdaAssetsTests`, `AdaAudioTests`, `AdaTextTests`, `AdaTransformTests`, `AdaUITests`, `AdaAnimationTests`, `AdaRenderTests`, `AdaInputTests`, `AdaUtilsTests`, `AdaSpriteTests`, `AdaSceneTests`, `MathTests`, and game tests. Confirm current names in `Package.swift` before filtering.

Use Swift Testing symbol/suite names with `--filter`; a target filter is broader than a single suite.

## Isolated SwiftPM Caches

The shared `.build` may contain artifacts from another Swift toolchain. If the first build reports incompatible modules, invalid PCM/AST data, or another clear cache mismatch, do not delete the user's shared `.build`. Retry with one task-owned scratch directory and reuse it:

```bash
swift test --scratch-path /tmp/adaengine-<task>-build --filter SomeSuiteName
swift build --scratch-path /tmp/adaengine-<task>-build
```

Large clean root builds compile substantial C/C++ dependencies and consume significant disk. Check available space before starting multiple scratch builds. Remove only task-owned temporary paths when cleanup is necessary.

SwiftPM resolution can rewrite `Package.resolved`. Inspect that diff after commands and retain only dependency changes required by the task.

## AdaEditor

```bash
swift build --package-path Editor --scratch-path /tmp/adaeditor-<task>-build
swift test --package-path Editor --scratch-path /tmp/adaeditor-<task>-build --filter SomeSuiteName
```

First verify local dependencies referenced by `Editor/Package.swift` exist. For generated macOS app work, run `xcodegen generate` in `Editor/`, build the `AdaEditor-macOS` scheme, inspect the staged `.app`, and launch/smoke-test when relevant.

## Lint and Static Checks

SwiftLint is attached as a build-tool plugin on supported hosts. If installed directly:

```bash
swiftlint --config .swiftlint.yml
```

Always finish with:

```bash
git diff --check
git status --short
git diff --stat
```

Review the actual task-owned diff, not only command exit status.

## Validation by Risk

- Pure local helper: focused suite/test and owning target build.
- ECS storage/query/scheduler: focused regression tests plus all `AdaECSTests`; add concurrency/access cases when relevant.
- Public cross-module API or macro: owning tests plus downstream compile/tests.
- AdaUI: focused behavior tests plus `AdaUITests`; run an actual UI path when interaction/rendering matters.
- Renderer/shader/assets: owning tests plus resource/shader compilation and a real render/demo smoke test where available.
- Editor: focused `AdaEditorTests`, editor package build, and executable/app interaction for runtime UX.
- Package/platform/plugin changes: dump/resolve/build the affected manifest configuration and validate the produced artifact.
- Broad foundational change: full `swift test --parallel` when environment and disk allow it.

If broader validation is blocked, report the focused evidence and exact blocker. Do not hide pre-existing failures or imply they were caused by the requested change without evidence.
