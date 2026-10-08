# Engine audit — 2026-09-05

Scope: SceneView, shared 2D rendering, Debug performance, and tilemaps.
These findings came from static inspection of the current implementation, not
a base-branch diff. Reproduce each scenario before fixing it; record corrections
to the diagnosis here. No current FPS or GPU correctness claims have been verified.

Status: `open`, `in progress`, `implemented` (validation incomplete), `verified`.
Original review numbers are stable identifiers.

## Work plan

1. Small tilemap fixes: 8, tileset replacement portion of 14, 15.
2. Sprite correctness: 5, 6, 7; add rendering regression coverage.
3. Tilemap ownership/lifecycle: 2, 9, 10, 11, 12, remaining 14.
4. LDtk import: 16.
5. SceneView lifecycle and scheduling: 1, 3, 4; validate hosted and standalone paths.
6. Profile a representative Debug scene, then address 13 and measured hot paths.

GPT-5.6 Luna completed the first batch. The user requested publication of all
current workspace changes before starting the next batch.
First batch and existing workspace changes published as `07fea4dd` on
`codex/gravity-ipados-project-foundation`; remote SHA verified with no divergence.
GPT-5.6 Luna completed sprite correctness (5, 6, 7), published as `f1e992ec`;
remote SHA verified with no divergence. Tilemap ownership/lifecycle
(2, 9, 10, 11, 12, remaining 14) is complete with headless validation;
these latest changes remain local and uncommitted. Next: LDtk flips (16).

## Findings and acceptance criteria

| ID | Priority | Status | Finding / location | Acceptance criterion |
| --- | --- | --- | --- | --- |
| 1 | P1 | open | SceneViewCoordinator.tick prepares a target before standaloneTick checks in-flight state. | Overlapping standalone ticks cannot leave unsubmitted targets blocking publication; rendering recovers after a slow update. |
| 2 | P1 | verified | TileEntityAtlasSource.getEntity returns the same entity for repeated cells. | Two cells referencing one entity tile create independent instances without duplicate-child assertions; define template/clone semantics. |
| 3 | P2 | open | OffscreenViewportContainerNode updates its factory but the existing coordinator retains the initial updateContent closure. | A parent rebuild updates captured values used by updateContent while make still runs once. |
| 4 | P2 | open | GameLoopBegan broadcasts globally from each world; AnimatedTexture consumes all broadcasts. | Adding/removing SceneViews does not change animation speed in another world. |
| 5 | P2 | verified | SpriteRenderSystem skips non-sprite items without ending the current batch. | Sprite/text/sprite depth order remains correct when sprites share a texture. |
| 6 | P2 | verified | SpriteRenderSystem uses the first texture size for subsequent sprites in a batch. | Different-sized slices of one atlas retain their own natural size when Sprite.size is nil. |
| 7 | P2 | verified | UpdateBoundings tracks Changed<Transform>, not changes to Sprite dimensions/texture. | Changing a stationary sprite's dimensions updates culling bounds. |
| 8 | P2 | verified | TileMap's default layer lacks the tileMap backreference. | Editing the default layer after a completed update dirties the owning map. |
| 9 | P2 | verified | TileMapSystem clears asset-level dirty flags after processing the first component. | Two components sharing one TileMap both initialize and receive subsequent edits. |
| 10 | P2 | verified | TileMapSystem creates TileRoot outside the owner hierarchy and bakes owner translation into cells. | Owner translation/rotation/scale propagate correctly and recursive owner deletion removes tiles. |
| 11 | P2 | verified | Removing a layer leaves its runtime entities behind. | removeLayer and LDtk layer removal delete stale roots and tileLayers entries. |
| 12 | P2 | verified | TileMapSystem applies isEnabled only to the old root before rebuilding it. | Initially disabled and rebuilt disabled layers remain inactive, including generated children. |
| 13 | P2 | open | A single changed cell deletes/recreates the entire layer. | Local edits preserve unaffected entity state; benchmark representative large maps before selecting cell/chunk storage. |
| 14 | P2 | verified | Tileset replacement does not dirty layers; zIndex and tileDisplaySize changes also lack effective invalidation. | Verified via world scheduling: replacing tileset, zIndex, and tileDisplaySize update existing tiles. |
| 15 | P2 | verified | TileSet auto source IDs can collide with previously supplied IDs. | Auto-added sources never overwrite a source with an existing explicit/loaded ID. |
| 16 | P2 | open | LDtk flipBits is decoded but not passed through cells to Sprite. | Horizontal, vertical, and combined flips match the LDtk level for grid and auto-layer tiles. |

## Validation record

- Publication check: 69 selected root-package tests and 48 selected Editor tests
  passed. The new ProjectOpeningLayoutTests fixture was made independent of
  other suites' renderer initialization and now waits for the observed form
  transition after the button click. No application launch was performed.

- Initial audit: static source/call-site inspection only; no tests or runtime run.
- Existing SceneView tests manually trigger completion; real GPU submission and
  overlapping standalone execution need additional coverage.
- No dedicated tilemap tests were found during the audit.
- Debug performance requires a fresh profile of the actual loaded scene;
  CPU vertex generation and layer rebuilding are candidates, not measured causes
  of the reported FPS.
- First implementation batch: three Swift Testing regressions passed in
  `Tests/AdaEngineTests/TileMapTests.swift`. They exercise actual asset state:
  default-layer edits after clearing dirty flags, replacement of the tileset
  across multiple layers, and explicit-ID preservation after auto insertion.
- `git diff --check` passed. No GPU/runtime visual checks or full suite were run.
- Initial manifest execution was blocked by the sandbox; the same command
  succeeded with elevated execution:

```sh
ADAENGINE_DISABLE_SWAN=1 \
CLANG_MODULE_CACHE_PATH=/tmp/adaengine-tilemap-first-fixes-clang-cache \
SWIFT_MODULE_CACHE_PATH=/tmp/adaengine-tilemap-first-fixes-clang-cache \
swift test --scratch-path /tmp/adaengine-tilemap-first-fixes-build --filter TileMapTests
```

### Sprite batch validation

- Three production-path headless regressions passed in SpriteRenderSystemTests:
  separation around a text item, same-atlas natural dimensions, and bounds after
  a stationary Sprite.size change.
- Broader validation: all 28 tests in AdaSpriteTests and VisibilitySystemTests
  passed using the same isolated build and `--skip-build`.
- Parent reviewed the source/test diff; `git diff --check` passed.
- GPU visual output and current Debug FPS remain unmeasured.

### Tilemap ownership/lifecycle validation

- Luna implemented per-owner map identity/revisions and per-layer revisions,
  independent entity tiles, owner hierarchy, layer removal, disabled rebuilds,
  and zIndex/display-size invalidation. Unchanged owners/layers keep their roots.
- Parent fixed required ECS dependencies: recursive removal now reads children
  before deleting their component storage; Entity.copy snapshots components from
  attached templates as well as detached entities. Sprite sort keys now use world
  Z so parent transforms also affect tile draw order.
- Entity tile templates copy component values only; parent/child relationships
  are cleared. This is not recursive subtree instantiation or deep copying of
  arbitrary reference-valued components.
- Final build/test run passed 127 tests across 17 suites, including 14 tilemap
  tests, all AdaECSTests, AdaSpriteTests, VisibilitySystemTests, and AdaTransformTests.
  Tests cover stationary frames, late consumers, equal-revision map replacement,
  unaffected layers/owners, translation/scale/rotation, actual tile deletion,
  dimensions, zIndex, and world-space sprite sort keys.
- `git diff --check` passed. GPU visual output and current Debug FPS remain
  unmeasured. Concurrent Editor edits were preserved and are outside this batch.

```sh
ADAENGINE_DISABLE_SWAN=1 \
CLANG_MODULE_CACHE_PATH=/tmp/adaengine-tilemap-first-fixes-clang-cache \
SWIFT_MODULE_CACHE_PATH=/tmp/adaengine-tilemap-first-fixes-clang-cache \
swift test --scratch-path /tmp/adaengine-tilemap-first-fixes-build \
  --filter 'AdaECSTests|TileMapTests|AdaSpriteTests|VisibilitySystemTests|AdaTransformTests'
```
