# Plan: Pixel Art Workflow Improvements

Design: [pixel-art-workflow.md](../Designs/pixel-art-workflow.md) (approved 2026-11-22)
Task: `pixel-art-workflow`

## Phases (TDD per phase: red → green → refactor)

### P1 — Sprite VM API (engine)

Files: `Sources/AdaScripting/AdaScriptSpriteGenerator.swift`,
`Sources/AdaAssets/Procedural/PixelCanvas.swift` (only if needed),
`Tests/AdaScriptingTests/AdaScriptMediaGeneratorTests.swift`.

- `sprite.palettePreset(name)`: bundled preset table compiled into
  AdaScripting (`pico-8`, `gameboy`, `nes`, `snes`, `db32`, `endesga-32`,
  `resurrect-64`, `sweetie-16`, `cga`, `commodore-64`).
  `AdaScriptSpriteGenerator.generate(source:userPalettes:)` accepts
  host-resolved `user:` presets; `sprite.palette(i,r,g,b)` overrides single
  entries after a preset.
- Layers: `sprite.beginLayer(name)` / `sprite.endLayer()`. The bridge owns the
  shared palette and per-layer index buffers; drawing targets the active
  layer; `beginLayer` with an existing name clears only it; the result
  flattens layers in creation order. Without `beginLayer` the behavior is
  byte-identical to today. `colorAt` reads the flattened composite.
- Frames: `sprite.size(w, h, frames)` (third argument optional, default 1).
  With frames > 1 the canvas is a horizontal strip; drawing calls address the
  cell selected by `sprite.frame(i)` (coordinates stay cell-local);
  `mirror()`/`outline()` apply to the active cell. `sprite.frameDuration(i,
  ms)`, `sprite.tag(name, from, to)` record animation metadata.
- Result carries `frames: [(rect, durationMs)]`, `tags`, `layers` and the
  recipe-facing summary; the editor tool writes `<name>.sheet.json` next to
  the PNG (atlas.pack-compatible shape) and reports layer/frame info.
- Red tests first in `AdaScriptMediaGeneratorTests`: preset colors exact,
  layer flatten order + isolated clear, strip layout + metadata, flat-API
  regression.

### P2 — Host tools (editor)

Files: `Editor/Sources/AdaEditor/Agent/EditorAgentGeneratorToolService.swift`
(or a sibling service), `Editor/Tests/AdaEditorTests/EditorAgentMediaGenerateTests.swift`.

- `editor.palette.extract`: project image (Assets path) → dominant colors
  (exact unique count when ≤ maxColors, else 5-bit/channel popularity) → JSON
  at `.ada/workspace/pixel-art/palettes/<name>.json`; returns colors + path.
  PNG decode reuses the engine's existing image decoding used by asset import.
- `user:` preset resolution: the sprite tool loads
  `.ada/workspace/pixel-art/palettes/*.json` and passes them to the generator.
- `editor.sprite.gif`: GIF89a encoder (global 256-color palette, LZW) in
  AdaAssets; tool renders a strip PNG (or sheet JSON range) to an animated
  GIF at integer scale, never overwrites.
- Red tests first in `EditorAgentMediaGenerateTests`: extract round-trip
  (acceptance #1), GIF header/frame count, user preset through the tool.

### P3 — A2UI image surface (editor UI)

Files: `Editor/Sources/AdaEditor/Agent/EditorAgentA2UIModels.swift` +
controller/stream + a test near existing A2UI tests.

- `image` component: project-relative PNG/GIF path, nearest-neighbor integer
  zoom, optional contact sheet for strips; rejects paths outside the project.
- Red test first: component model renders a fixture PNG and rejects escape
  paths.

### P4 — Skill rewrite

Files: `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-pixel-art/`
(`SKILL.md`, `palettes/*.json`, `references/*.md`, `NOTICE.md`).

- Restructure per design: decision tree, palette-first workflow, layers,
  frames/atlas, tmp recipe persistence under `.ada/workspace/pixel-art/`,
  chat preview loop. Palettes + craft references adapted from
  ervareza/agent-skill-pixel-art (MIT) with NOTICE.
- Existing bundled-skill example tests keep passing; new examples for
  preset/layers/frames run in tests.

### P5 — Docs and acceptance

- Update the pixel art user documentation (agent guides) with palettes,
  layers, frames, tmp workflow, chat preview and limitations.
- Declare `article`/`navigation` in the runner; run `check_contribution.py`
  stages; independent review (subagent); `record-review`; `verify`.
- E2E: launch Ada Studio, ask the agent to create a sprite + animation,
  verify chat preview and assets (user-requested acceptance).

## Notes

- `Editor/Package.resolved` must stay untouched in commits (SwiftPM rewrites
  it with local-path deps); reset before runner commands.
- Windows Swift runs go through PowerShell with the toolchain env (see task
  history): Swift 6.3.1 toolchain + runtime in PATH, `SDKROOT`,
  `ADAEDITOR_SWIFTTERM_PACKAGE_PATH`, `LORE_WINDOWS_SDK_PATH`,
  `ADA_MCP_LOCAL_PATH`.
