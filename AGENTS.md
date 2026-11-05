# AdaEngine Agent Guide

This file is for coding agents working in this repository. It focuses on
Swift 6.2, Swift Concurrency, and AdaEngine-specific workflows.

## Project Overview
- Language: Swift 6.2 (swift-tools-version: 6.2).
- Build system: Swift Package Manager (SwiftPM).
- CI: SwiftPM tests on macOS 26 and Windows using `swift test --parallel`.
- Linting: SwiftLint via SwiftLintPlugins and `.swiftlint.yml`.

## Ada Studio Visual Design Rules

Apply these rules to Ada Studio/editor interfaces on desktop, web, and iOS, including
dialogs, settings, inspectors, toolbars, onboarding, and reusable controls. They describe
required design behavior; verify existing controls rather than assuming they already comply.
Game-authored UI follows its own art direction unless the task explicitly adopts Studio styling.

### Before changing UI

- Use [adaengine-studio-design](.agents/skills/adaengine-studio-design/SKILL.md) and
  [ui-ux-pro-max](.agents/skills/ui-ux-pro-max/SKILL.md) for Studio visual/interaction work.
  Use the engineering skills below when the task also changes implementation behavior.
- Inspect the affected screen, neighboring controls, existing theme tokens, and target platform.
  Shared editor UI is AdaUI; do not infer SwiftUI support from Swift syntax or introduce a web
  styling framework into the native editor. Reuse the owning platform's existing components.
- **Present a visual proposal before production UI implementation**: a rendered mockup,
  annotated screenshot, or runnable preview showing layout, controls, spacing, and key states.
  For a small visual fix, an annotated crop of the affected control is enough.
  Reuse an already approved visual when it covers the change; seek approval for a new visual
  direction through the existing feature/design workflow. A prose-only plan is not a visual.
- Use **IntelliJ IDEA, Android Studio, Zed, and Godot** as references for a focused editor:
  compact consistent controls, clear panel hierarchy, readable typography, restrained accents,
  and predictable navigation. Preserve Ada Studio's identity and existing theme tokens.
  Avoid decorative marketing layouts in working editor panels.

### Controls and visual consistency

- **Buttons:** show a themed background or visible border, with distinct hover feedback on
  pointer devices. Toolbar/icon buttons may have a quiet resting surface but must reveal a
  background or border on hover and keyboard focus. Provide pressed, focused, disabled, and
  selected states where applicable; a persistent selected state must survive mouse exit.
  Use real button semantics, not clickable text or a generic container.
- **Dropdowns:** when an interaction calls for a dropdown, use the shared `DropDown`/select
  control or the owning platform's equivalent. Show the current value and disclosure affordance;
  support opening, selection, dismissal, focus return, keyboard navigation, and scrolling long lists.
  Use a combo box only when text entry/search is part of the requirement.
- **Text fields:** use the application theme, a visible border, dark input surface, readable
  text/placeholder, and a **white text insertion caret in Studio's dark theme**. Show focus and
  validation errors without changing layout. Provide labels rather than placeholder-only names.
  If a supported alternate theme changes these colors, use its corresponding contrast-safe tokens.
- **Boolean settings:** prefer a `Toggle` for an immediate on/off setting. Use checkboxes for
  multi-selection or deferred form choices, segmented controls/radio buttons for mutually
  exclusive modes, and buttons for commands. Choose by meaning and available space.
- **Icons:** prefer **Material Icons / Material Symbols**, using the existing bundled font or
  asset helper. Keep size, weight, optical alignment, and filled/outlined style consistent.
  Do not substitute emoji or arbitrary Unicode glyphs for interface icons. Add localized tooltips
  describing icon actions and shortcuts when available, plus accessible names for icon-only
  controls. Decorative icons beside an explicit label need no duplicate tooltip/name.
- **Theme and layout:** reuse semantic colors, typography, spacing, borders, radii, and shared
  control styles. Add missing reusable roles to the existing theme instead of hardcoding a new
  palette per screen. Keep alignment, control heights, padding, and panel density consistent.
  Support long English/Russian labels, empty/error/loading states, and narrow windows.
- **Fonts and visual direction:** use only Studio's existing font assets and text roles.
  Do not add font files, remote font imports, substitute font families, font-pairing catalogs,
  or alternative visual style/palette catalogs. Build new UI within the existing Studio theme.
  Keep readability, wrapping, glyph coverage, and text-scaling checks for the actual Studio fonts.
- **Accessibility:** provide visible keyboard focus, logical navigation, readable contrast, and
  non-color cues for state. Tooltips supplement labels and accessibility semantics.
  Keep animations subtle and respect reduced-motion preferences.

### iOS and touch

- Design for fingers: at least **44 x 44 pt** tappable areas, including small icons, with enough
  separation to prevent adjacent actions firing accidentally. A larger hit area may surround a
  smaller visual icon; it must not overlap another control's hit area.
- Provide immediate pressed feedback. Essential actions, help, and state must work without hover;
  expose icon meaning through visible labels, accessible names, or a touch-operable help affordance.
- Respect safe areas, the on-screen keyboard, text scaling, orientation, and compact/expanded layouts.
  Adapt desktop density for touch rather than shrinking a desktop toolbar onto a phone.

### Required visual verification

- Inspect the **rendered result** on each affected platform against the approved proposal and
  these rules. Build success, source inspection, and unit tests alone do not prove visual quality.
- Exercise default, hover (pointer), pressed, focus, disabled, selected, open, and error states
  where applicable. Check dropdowns, caret visibility, icon tooltips, keyboard use, and touch targets.
- Check the supported themes, narrow/normal layouts, scaling, English/Russian text, and relevant
  empty/loading/error content. Confirm no clipping, overlaps, invisible borders, or focus loss.
- Include screenshots/preview paths and a brief compliance result in the handoff. Name the
  platforms and states actually checked; report unavailable runtime/device checks as blocked.
  Fix discrepancies before declaring the UI complete. Include this evidence in independent review.

## Build, Lint, Test Commands

### Contributor workflow and required validation

- Follow [the accepted contributor workflow](Documentation/Designs/contributor-workflow.md).
  Use [adaengine-feature-flow](.agents/skills/adaengine-feature-flow/SKILL.md) for new features
  and extensions/reworking of existing subsystems. Adding SVGSerializer to an existing importer
  is an improvement. Ask the human if classification is uncertain.
- For features, use Task → Enrich → Design → human approval → Plan → Code → Review.
  Offer the project flow when detecting a new feature; use the repository-local
  [Enrich skill](.agents/skills/adaengine-enrich/SKILL.md), not a personally installed dependency.
- Design documents are English-only. Give the actual document to the human and wait for explicit
  approval before the next stage. Improvements update the existing design or create a concise one
  if missing. Bugs within the existing contract do not need a new permanent PRD/design/plan.
- Use [the TDD skill](.agents/skills/adaengine-tdd/SKILL.md) for testable behavior and fixes.
  Record meaningful Red → Green → Refactor evidence; infrastructure failures are not Red.
- Every feature ships a discoverable user-facing article or substantial relevant guide update in the same change.
  Declare article/navigation and example/docs checks in Design/Plan; update them before independent review.
  Author in the relevant DocC catalog or user-guide source, not generated `docs/`. Designs, ADRs, changelogs,
  and agent knowledge do not replace the article. User-facing improvements update guides; internal-only
  improvements require a reviewed reason. See [user documentation](.agents/knowledge/user-documentation.md).
- Run `python script/check_contribution.py` before advancing stages; command examples and setup
  are in [workflow commands](.agents/knowledge/workflow.md). The script runs lint, analyzers,
  tests and applicable security/runtime checks with compact output and full local logs.
  Install its pinned tools explicitly in Python 3.11+ with `python -m pip install -r script/contribution-requirements.txt`.
- Record exact task-owned files and expand scope as files are added. Preserve unrelated user work.
  Missing tools/platforms are blocked, not inapplicable. Do not weaken checks, add suppressions,
  hardcode a passing outcome, remove tests, or claim unexecuted checks passed.
- Before closing any code task, use [adaengine-review](.agents/skills/adaengine-review/SKILL.md)
  in a separate subagent context. Another model is optional. Fix findings and repeat affected
  checks/review; design ambiguities or deviations require the human. Self-review is not independent review.
- Read [the knowledge index](.agents/knowledge/README.md) and only the relevant subsystem references.
  Actual code describes current behavior; accepted designs specify required behavior. Report conflicts.
- `install-hooks` explicitly connects pre-commit/pre-push checks while preserving existing hooks.
  Hooks are bypassable; hosted required checks remain necessary. A local report does not prove CI
  or server-side branch protection is enabled.
- Pre-push uses local checks plus mandatory CI. A locally unavailable check may be `deferred` only
  through a validated workflow/job mapping in `.agents/validation.json`; failed local checks and
  unmapped prerequisites still block publication. Publication reports cannot close tasks or count
  pending CI as passed. `run --stage review` and `verify --stage done` retain complete validation requirements.

### Unified developer CLI
- Use `python ada_tool.py` from the repository root (Python 3.9+, standard library only;
  `python3` on hosts where that is the Python command). Guide: [Documentation/Tooling.md](Documentation/Tooling.md).
- `python ada_tool.py doctor` reports missing tools and fixes without installing/downloading.
  Use `--profile studio|wasm|playground` to narrow checks and `--json` for automation;
  exit code 1 means a required dependency is missing.
- `python ada_tool.py prepare` installs system prerequisites, pinned Swift, Tint, native
  Studio dependencies, the WASM SDK and Node/pnpm frontend dependencies. Select components
  with `prepare studio`, `prepare swift`, `prepare tint`, `prepare wasm` or `prepare playground`.
  `--skip-system` skips apt/brew/winget prerequisites; it does not skip toolchain downloads.
  Windows WASM uses the existing Ubuntu 24.04 WSL worker; WSL must already be enabled.
- `python ada_tool.py install studio` builds and installs Release Standalone;
  `--debug` installs Debug alongside Release with a separate folder/shortcut.
  `--source PATH` installs a complete extracted distribution or macOS `.app` without compiling;
  `--destination PATH` names the exact application folder, including `.app` on macOS.
  `--launch` opens it after installation. Defaults are per-user, including `~/Applications` on macOS.
- `python ada_tool.py build studio|engine` builds without installing; `--debug`, `--jobs N`,
  `--scratch-path PATH` and `--swift PATH` select the build configuration/tools.
  `python ada_tool.py run studio [--debug]` opens an installed distribution.
- `python ada_tool.py build playground --cloud-panels PATH` builds the existing DOM shell;
  the panels must first be built in adawebsite with `npm run build:panels`.
  `python ada_tool.py build wasm --output dist/web` exports DOM Studio and AdaWebPlayer,
  using WSL on Windows. `--ui-dist PATH` reuses a built frontend.
  `python ada_tool.py serve playground|wasm` provides a loopback static preview, without Cloud services.
- Mutating commands support `--dry-run`; no installers, downloads or builds run in that mode.
  Host-specific state and default scratch directories live under `.build-tools/ada-tool/<os>-<arch>/`;
  compiler logs are there too. Do not delete the user's shared `.build`.
- Version policy lives in [Tools/ada-toolchain.json](Tools/ada-toolchain.json): Windows native
  Swift 6.3.1, macOS/Linux and WASM Swift 6.3.2; the engine language mode remains Swift 6.2.
  Tint/Lore retain their existing pins. The CLI reads the pnpm pin from `Editor/WebUI/package.json`.
  Windows Dawn requires MSVC 14.44+ (VS 2022 17.14+); `doctor` rejects older toolsets
  before a build, and `prepare studio` upgrades existing VS 2022 Build Tools when necessary.
- Keep implementation in `script/ada_tools/`. Test with `python script/test_ada_tool.py`.
  Existing platform installers/packagers, bootstrap helpers, GPU validators and their tests
  remain used by CLI/CI/plugins/release distributions. Do not delete them as temporary task scripts
  without checking their callers and migrating those callers.

### Build
- SwiftPM build: `swift build`
- Build docs: see Documentation section below.

#### Swift Toolchain Cache Compatibility
- The shared `.build` directory may contain modules produced by a different Swift toolchain. If the first build or test reports that a module was compiled with another Swift version and cannot be imported, treat it as a stale-cache/toolchain mismatch rather than a source failure.
- Do not delete or rewrite the user's shared `.build` directory. Immediately retry with an isolated scratch directory, for example: `swift test --scratch-path /tmp/adaengine-swift-build --filter SomeSuiteName` or `swift build --scratch-path /tmp/adaengine-swift-build`.
- Reuse the same scratch path for subsequent commands in the task so the clean build remains incremental.

### WebGPU shader validation
- For shader, sprite-renderer or WebGPU changes, run `script/validate_webgpu.sh`
  from the engine root with compatible Swan/Dawn and Swift 6.3.2. It bootstraps
  pinned Tint and tests a fresh SPIR-V → WGSL conversion plus actual GPU pixels.
- The script also runs the 3D GPU suites (`Render3DGPUTests`) on WebGPU against the
  references in `Tests/AdaEngineTests/GoldenFrames/webgpu` and checks that they agree
  with the Metal references. It runs its package sequentially because the engine owns
  one process-wide renderer.
- `python3 script/ensure_tint.py --check` verifies the installed tool hash and
  reader/writer smoke. Do not treat cached WGSL as proof of current Tint behavior.
- Tool setup and overrides are documented in [Tools/Tint/README.md](Tools/Tint/README.md).

### Test
- **Use Swift Testing** for AdaEngine package tests: `import Testing`, `@Suite`, `@Test`, and `#expect` / `#require`. Do not add new **XCTest**-based tests in `AdaEngine/Tests/`.
- 3D rendering is checked with golden frames. The GPU suites are gated by
  `ADAENGINE_GOLDEN_METAL=1` (run `swift test --filter Render3DGPUTests`) or
  `ADAENGINE_GOLDEN_WEBGPU=1` (through `script/validate_webgpu.sh`). References live in
  `Tests/AdaEngineTests/GoldenFrames/<backend>`; re-record with `ADAENGINE_GOLDEN_RECORD=1`
  and review the diff images written to `ADAENGINE_GOLDEN_OUTPUT` on a mismatch. Keep every
  GPU suite nested under `Render3DGPUTests`, which serializes them.
- Measure 3D performance with the benchmark, never by eye: `ADAENGINE_PERF=1 ADAENGINE_GOLDEN_METAL=1
  swift test -c release -Xswiftc -enable-testing --filter Render3DGPUTests/Benchmarks` (options and
  interpretation in ADR-0027, "Performance pass 1"). Run it on a quiet machine; other GPU work inflates results.
- Run all tests: `swift test --parallel`
- Run a single test target:
  - `swift test --parallel --filter AdaEngineTests`
- Run a single test (SwiftPM `--filter` matches symbol names; Swift Testing suites are often filterable by suite string):
  - `swift test --filter SomeSuiteName`
  - `swift test --filter AdaSpriteTests`

### Lint
- SwiftLint is wired as a SwiftPM build tool plugin for macOS/Linux.
- Run SwiftLint manually (if installed): `swiftlint --config .swiftlint.yml`
- AdaScript layout is checked by `AdaScriptLinter` in `AdaScriptCompilerCore` and
  published as `adascript-lint` workspace warnings. Fix these after script edits.
  Desktop projects can enforce them with
  `adastudio validate --project <directory> --lint strict --format json`
  (exit code 3 for style violations). Rules and modes:
  [Editor/Documentation/AdaScriptLint.md](Editor/Documentation/AdaScriptLint.md).

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

Repository-local skills live in `.agents/skills/`. Read the applicable `SKILL.md`; do not load
the entire catalog for every task. The two Studio skills retain practical UI construction and
verification guidance. The Studio rules and accepted designs govern the existing theme/fonts;
the skills do not select a new visual identity or authorize framework migrations.

| Skill | When to use |
| --- | --- |
| [adaengine-development](.agents/skills/adaengine-development/SKILL.md) | Engine/editor implementation and architecture |
| [adaengine-enrich](.agents/skills/adaengine-enrich/SKILL.md) | Resolve feature requirements and design decisions |
| [adaengine-feature-flow](.agents/skills/adaengine-feature-flow/SKILL.md) | Feature/improvement stages and approval |
| [adaengine-tdd](.agents/skills/adaengine-tdd/SKILL.md) | Testable behavior and fixes |
| [adaengine-review](.agents/skills/adaengine-review/SKILL.md) | Independent review before completion |
| [adaengine-studio-design](.agents/skills/adaengine-studio-design/SKILL.md) | Studio visual proposal, controls, and rendered compliance review |
| [ui-ux-pro-max](.agents/skills/ui-ux-pro-max/SKILL.md) | UI/UX research, interaction, accessibility, and visual review |

The practical UI/UX guidance is adapted from
[nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill).
Its source revision, retained license, and reduced scope are recorded in
[design skill provenance](.agents/skills/design-skills-provenance.md).

Engineering competencies:

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
