# Pixel Art Workflow Improvements

Status: proposed (pending human approval)
Kind: improvement of scripted asset generation (extends [ADR-0026](../ArchitectureDecisions/0026-scripted-asset-generation-and-autonomous-studio.md))
Date: 2026-11-22

## Context

Ada Studio already ships a code-drawn pixel art path: `editor.sprite.generate`
runs an agent-authored AdaScript `build(sprite)` program in an isolated VM and
writes a `.png` under the assets root, `editor.atlas.pack` slices sheets,
`editor.image.read` lets the agent inspect the result, and the bundled
`ada-pixel-art` skill documents the flat single-canvas API
(`pixel/rect/line/ellipse/fill/mirror/outline`, palette indices, 64 KiB source
limit, no file access).

User request (2026-11-22): improve the pixel art generation so the agent can

1. hold a consistent style — named palettes and explicit style guidance;
2. produce a single sprite or an animation atlas, not only flat canvases;
3. show the finished result in the chat (image or animation), not only read it
   back for self-check;
4. think in layers (shadow / body / weapon / fx) instead of one flat canvas;
5. keep its generator scripts in a tmp directory and patch them incrementally
   instead of recreating the source on every fix.

External research (2026-11-22) compared three published approaches:

- **ervareza/agent-skill-pixel-art** (MIT): a skill folder with Python CLI
  scripts, 11 named palettes (PICO-8, GameBoy, NES, SNES, DB32, Endesga-32,
  Sweetie-16, Resurrect-64, CGA, C64), and pixel art craft references.
- **Aseprite MCP servers** (pixel-art-ai, aseprite-mcp): compact text drawing
  (color legend + character rows), preview images returned to the agent,
  layer/frame/tag management, spritesheet + JSON export. Requires a paid
  Aseprite install; rejected as a dependency.
- **AI image model + conversion pass** (Sprite Fusion, Pixel Snap): needs an
  image generation provider, which the user may not have connected; rejected as
  the baseline (the agent draws with code).

Decision (user, 2026-11-22): adapt the ervareza skill's palettes and craft
knowledge under its MIT license with attribution, and build the rest on the
existing AdaScript sprite VM. The image generation provider stays optional and
out of scope.

## Working assumptions (settled in the Enrich interview by recommended defaults; confirmed or corrected at this design's approval)

- Scope: one iteration covering the skill rewrite, the VM API additions and the
  chat preview component.
- Layers are a real VM API, not a documentation convention.
- Chat preview is a new A2UI image surface; opening the asset in the Studio
  panel is the fallback.
- Recipes live in `<project>/.ada/workspace/pixel-art/`, next to the existing
  `agent-captures` convention; palettes and craft references are adapted from
  ervareza/agent-skill-pixel-art with a NOTICE attribution.

## Design

### Named palettes and style

- The sprite VM gains `sprite.palettePreset(name)`: loads a bundled named
  palette (`pico-8`, `gameboy`, `nes`, `snes`, `db32`, `endesga-32`,
  `resurrect-64`, `sweetie-16`, `cga`, `commodore-64`, plus `custom` as today).
  Presets are compiled into the host tool; the isolated VM keeps its
  no-file-access rule. `sprite.palette(i, r, g, b)` after a preset overrides
  single entries.
- Palette definitions ship as JSON under
  `Editor/Sources/AdaEditor/Assets/AgentSkills/ada-pixel-art/palettes/`,
  adapted from the upstream skill, and are also readable by agents for
  planning. A test asserts the bundled JSONs and the host presets agree.
- Custom palettes from user images: when the user drops a reference image into
  the chat, the agent imports it into the project and calls the new host-side
  tool `editor.palette.extract(image, maxColors, name)`. The tool extracts the
  dominant colors (bounded quantization, default 16), writes a palette JSON to
  `.ada/workspace/pixel-art/palettes/<name>.json` and returns the colors and
  path. `sprite.palettePreset("user:<name>")` then resolves that project JSON
  on the host and injects the colors into the VM call, so the isolated VM
  keeps its no-file-access rule; bundled and user presets share one mechanism.
- The rewritten `ada-pixel-art` skill teaches the palette-first workflow:
  pick size and palette before drawing, one palette per game, 4–8 working
  colors per sprite, top-right light source, no anti-aliasing, draw at final
  size, mirror symmetric directions. Craft references (animation principles,
  tileset rules, color theory, UI elements, particles) are adapted into the
  skill's `references/` with attribution.

### Layers

- New VM calls: `sprite.beginLayer(name)` / `sprite.endLayer()`. Drawing calls
  between them go to that named layer; layers composite in creation order onto
  the flattened canvas. `colorAt` reads the flattened result.
- Redrawing a layer restarts it: `beginLayer` with an existing name clears
  that layer. The final PNG is always the flattened composite; layer names are
  recorded in the generation result for the agent.
- The skill documents the convention `shadow` → `body` → `weapon` → `fx` and
  when to keep layers separate (recolor, re-pose one part, per-layer audit).

### Frames, animation atlas and GIF preview

- `sprite.size(w, h, frames)` gains an optional frame count. With frames, the
  canvas is a horizontal strip of `frames` cells of `w × h`; `sprite.frame(i)`
  selects the cell that drawing calls address (coordinates stay cell-local).
  `sprite.frameDuration(i, ms)` sets per-frame timing; `sprite.tag(name, from,
  to)` names frame ranges (`walk`, `idle`).
- Generation writes the strip PNG plus a sidecar JSON (`<name>.sheet.json`):
  frame rects, durations, tags — the same shape `editor.atlas.pack` produces,
  so the result feeds `Sprite` animation and tile sources without a second
  packing step. Single-frame generation keeps its current behavior and writes
  no sidecar.
- New tool `editor.sprite.gif`: renders a sheet (or a frame range) into an
  animated GIF with nearest-neighbor integer scaling, for chat preview and
  quick checks. It never overwrites; output goes next to the sheet or to the
  workspace tmp directory.

### Recipe persistence in tmp

- The skill instructs the agent to save each generator script to
  `<project>/.ada/workspace/pixel-art/<name>.adas` before calling
  `editor.sprite.generate`, and to patch that file on fixes instead of
  rewriting from scratch. The tool keeps its inline `source` contract (64 KiB
  limit) in this iteration; the tmp file is the agent's persistent working
  copy, and the generated sidecar JSON records the recipe path for
  traceability.

### Chat preview

- New A2UI surface component `image`: renders a project-relative PNG or GIF
  file in the agent chat at nearest-neighbor integer zoom (pixel-perfect),
  with an optional frame contact sheet for sheets. Only files inside the
  project are renderable; paths outside are rejected.
- The skill's verification loop becomes: generate → `editor.sprite.gif` for
  animations → show the PNG/GIF in chat via the `image` surface →
  `editor.image.read` self-check → fix the recipe file → regenerate.
- Fallback where A2UI is unavailable: the agent opens the asset in the Studio
  assets panel and says so.

### Skill rewrite

- `ada-pixel-art` is restructured after the upstream skill: `SKILL.md`
  (decision tree, workflow, API), `palettes/`, `references/`, and a `NOTICE.md`
  with the upstream MIT attribution. Existing flat-API scripts keep working
  unchanged; layers and frames are additive.

## Acceptance criteria

1. A script using `palettePreset("pico-8")` renders with exactly the bundled
   PICO-8 colors; bundled JSON and host presets are asserted equal. A palette
   extracted from a user image round-trips: `editor.palette.extract` writes the
   JSON, `palettePreset("user:<name>")` renders with exactly those colors.
2. A two-layer script (`body`, `fx`) flattens in order; re-running
   `beginLayer("fx")` clears only that layer; existing single-canvas scripts
   are unaffected.
3. A 4-frame strip generates a PNG plus `.sheet.json` with rects, durations
   and a `walk` tag; the JSON loads through the same path as `atlas.pack`
   output.
4. `editor.sprite.gif` produces a looping GIF at integer scale from a strip.
5. The A2UI `image` surface renders a project PNG and a GIF in the chat at
   nearest-neighbor zoom and rejects paths outside the project.
6. The rewritten skill's examples run in the bundled-skill example tests.
7. User documentation: the pixel art guide documents palettes, layers,
   frames, the tmp workflow and chat preview, with limitations (no AI provider
   needed, flat API unchanged).

## Out of scope

- Image generation provider integration and AI-image conversion pipelines.
- Aseprite or other external editor integrations.
- Tilemap painting UI; `editor.tileset.create`/`tilemap.write` are unchanged.
- Music/voice providers (unchanged from ADR-0026).

## Attribution

Palettes and craft references are adapted from
[ervareza/agent-skill-pixel-art](https://github.com/ervareza/agent-skill-pixel-art)
(MIT). The full license text ships in `NOTICE.md` inside the skill folder.
