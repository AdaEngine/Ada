# AdaEngine Agent Guide

This file is for coding agents working in this repository. It focuses on
Swift 6.2, Swift Concurrency, and AdaEngine-specific workflows.

## Project Overview
- Language: Swift 6.2 (swift-tools-version: 6.2).
- Build system: Swift Package Manager (SwiftPM).
- CI: SwiftPM tests on macOS 26 and Windows using `swift test --parallel`.
- Linting: SwiftLint via SwiftLintPlugins and `.swiftlint.yml`.

## Build, Lint, Test Commands

### Build
- SwiftPM build: `swift build`
- Build docs: see Documentation section below.

#### Swift Toolchain Cache Compatibility
- The shared `.build` directory may contain modules produced by a different Swift toolchain. If the first build or test reports that a module was compiled with another Swift version and cannot be imported, treat it as a stale-cache/toolchain mismatch rather than a source failure.
- Do not delete or rewrite the user's shared `.build` directory. Immediately retry with an isolated scratch directory, for example: `swift test --scratch-path /tmp/adaengine-swift-build --filter SomeSuiteName` or `swift build --scratch-path /tmp/adaengine-swift-build`.
- Reuse the same scratch path for subsequent commands in the task so the clean build remains incremental.

### Test
- **Use Swift Testing** for AdaEngine package tests: `import Testing`, `@Suite`, `@Test`, and `#expect` / `#require`. Do not add new **XCTest**-based tests in `AdaEngine/Tests/`.
- Run all tests: `swift test --parallel`
- Run a single test target:
  - `swift test --parallel --filter AdaEngineTests`
- Run a single test (SwiftPM `--filter` matches symbol names; Swift Testing suites are often filterable by suite string):
  - `swift test --filter SomeSuiteName`
  - `swift test --filter AdaSpriteTests`

### Lint
- SwiftLint is wired as a SwiftPM build tool plugin for macOS/Linux.
- Run SwiftLint manually (if installed): `swiftlint --config .swiftlint.yml`

### Documentation
- Build docs (from CI workflow):
  - `swift package --allow-writing-to-directory ./docs \
    generate-documentation \
    --output-path ./docs \
    --transform-for-static-hosting \
    --hosting-base-path adaengine-docs \
    --enable-experimental-combined-documentation \
    --target AdaEngine --target AdaECS --target AdaScripting --target AdaRender --target AdaUI \
    --target AdaApp --target AdaPlatform --target AdaAssets --target AdaAudio \
    --target AdaTransform --target AdaText --target AdaInput --target AdaScene \
    --target AdaTilemap --target AdaPhysics --target AdaSprite --target AdaUtils \
    --target Math`

## Platform and Tooling Notes
- Recommended editor: Xcode 26.2 or VSCode with Swift extension.

## Swift 6.2 + Concurrency Rules (Agent Requirements)

### Actor Isolation and Sendable
- Default to actor isolation. Mark UI or app lifecycle types with
  `@MainActor` when they interact with UI or platform APIs.
- Prefer `Sendable` for data passed across concurrency boundaries.
- Avoid `nonisolated(unsafe)` unless there is a strong justification and
  the type is immutable or externally synchronized.
- Use `@Sendable` for closures captured by concurrency primitives.

### Structured Concurrency
- Prefer `async`/`await` and structured tasks (`Task`, `withTaskGroup`).
- Avoid detached tasks unless necessary; document why detaching is safe.
- Do not block threads with sleep or busy-wait; use async APIs.

### Error Handling in Concurrency
- Prefer `throws` + typed errors. Avoid `fatalError` and `precondition` in
  production paths unless required by invariants.
- In `catch`, avoid `Error` erasure when practical; use typed errors.
- When bridging to C APIs, validate error codes and surface Swift errors.

### Data Races and Mutability
- Avoid global mutable state. If needed, guard it with actors or locks.
- For shared mutable state, prefer actors or `ManagedAtomic` (used in ECS).
- Validate `@unchecked Sendable` usage with explicit reasoning.

### Performance and ECS
- Keep hot paths allocation-free where possible.
- Prefer value types and `struct` for data; use `class` for shared identity
  and reference semantics.
- Be mindful of copy-on-write for large arrays in ECS logic.

## Code Style Guidelines

### Imports
- Keep imports minimal and sorted; SwiftLint enforces `sorted_imports`.
- Use platform conditionals for OS-specific imports (`Darwin`, `Glibc`,
  `WinSDK`).
- Prefer `@_spi(Internal)` or `@_spi(Runtime)` only when already used in
  a module boundary.

### Formatting
- Line length: 190.
- Follow SwiftLint rules in `.swiftlint.yml`.
- Prefer multi-line arguments and parameters when they do not fit on one
  line; SwiftLint enforces multiline argument/parameter styles.
- Keep file length under 600 lines (warning) and 1200 (error).
- Keep type body length under 300 lines (warning) and 400 (error).

### Naming
- Type names: 3-40 chars (warning) and 50 (error). `ID` and `iPhone` are
  allowed. Underscores are allowed in type names.
- Prefer `lowerCamelCase` for variables and functions; `UpperCamelCase` for
  types; `SCREAMING_SNAKE_CASE` for constants only when required.

### API Design
- Use `@discardableResult` when returning `Self` for fluent APIs (common in
  ECS world APIs).
- Prefer `public` APIs to be documented with doc comments when behavior is
  non-obvious or part of stable surface area.
- Use `borrowing`/`consuming` keywords for ownership clarity (already used
  in ECS). Keep usage consistent with existing patterns.

### Error Handling
- Avoid force unwraps; SwiftLint `force_unwrapping` is enabled.
- `force_try` is allowed but warns; prefer `do`/`try`/`catch`.
- Use `assertionFailure` for unreachable paths in debug-only code.

### Testing
- Prefer **Swift Testing** (`@Suite`, `@Test`, `#expect`) over XCTest for new
  and migrated tests under `AdaEngine/Tests/`.
- Use descriptive suite and test names; `yoda_condition` and
  `optional_enum_case_matching` are enabled.

### Types and Access Control
- Prefer `struct` for value types, `final class` for non-inheritable
  reference types.
- Use `private` and `fileprivate` intentionally; `strict_fileprivate` is
  enabled.
- Favor `internal` for cross-target use and `public` only when required by
  API surface.

### Concurrency Annotations
- Use `@MainActor` on app lifecycle, UI, and platform glue.
- Use `@globalActor` for domain-specific synchronization (e.g. `WorldActor`).
- For cross-actor access, prefer explicit `await` and isolate mutation.

## SwiftLint Rules to Respect
- Enabled opt-in rules include: `sorted_imports`, `force_unwrapping`,
  `untyped_error_in_catch`, `type_contents_order`, `modifier_order`.
- Disabled defaults include: `trailing_whitespace`, `trailing_comma`,
  `identifier_name`, `function_parameter_count`, `force_cast`.
- Analyzer rules: `capture_variable`, `unused_declaration`, `unused_import`.

## Agent Workflow Expectations
- Avoid editing vendored or third-party sources under `Sources/*` that are
  not part of AdaEngine (e.g., glslang, libpng) unless required.
- Keep changes local to relevant targets; avoid sweeping refactors.
- Add tests for new behavior in the nearest test target when practical.

## Skills for Agents (Swift 6.2 + Concurrency)
- SwiftPM and SwiftLint usage in Swift 6.2 projects.
- Swift Concurrency correctness: actor isolation, Sendable, structured
  concurrency patterns, async-safe APIs.
- ECS patterns used in AdaEngine (systems, schedulers, world queries).
- Cross-platform Swift: conditional compilation for Apple, Linux, Windows.
- Documentation authoring with DocC and SwiftPM.
- Performance-aware Swift (value semantics, avoiding copies, atomics).

## Notes on Missing Rules
- No `.cursor/rules`, `.cursorrules`, or `.github/copilot-instructions.md`
  files exist in this repo at the time this guide was generated.
