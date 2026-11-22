# AI-assisted pixel art in Ada Studio

Studio's agent draws pixel art as real PNG files: you describe the picture, the
agent writes a small AdaScript program, and Studio renders it in an isolated VM.
The bundled `ada-pixel-art` skill teaches agents this workflow; it is advertised
in every desktop and mobile session and loads on demand through
`editor.skills.read` with `id: "ada-pixel-art"`. Painted or photographic art is
out of scope — that needs the image generation provider (`editor.image.generate`)
when one is configured.

## Recipes instead of one-shot scripts

Agents keep every drawing program as a recipe file under
`.ada/workspace/pixel-art/<name>.adas` (written with `editor.file.write`) and
pass its text to `editor.sprite.generate` together with the recipe path. The
recipe is recorded in the sheet metadata, and revisions patch the saved recipe
(`editor.file.patch`) instead of rewriting from scratch, so iterations stay
small and reviewable. The VM is isolated: no file, network, scene or engine
access, a 64 KiB source limit and a small time/step budget, with errors returned
as text.

## Palettes and consistent style

A palette is chosen before drawing and stays fixed for the whole game. Ten
bundled presets cover the classic machines and community standards: `pico-8`,
`gameboy`, `nes`, `snes`, `cga`, `commodore-64`, `db32`, `endesga-32`,
`resurrect-64` and `sweetie-16`. `sprite.palettePreset("pico-8")` fills palette
indices in the listed order and also works before `sprite.size`.

When you provide reference art, the agent calls `editor.palette.extract` with
the image path, a short name and an optional `maxColors` (default 16). The
extracted palette is saved to `.ada/workspace/pixel-art/palettes/<name>.json`
and loaded in scripts as `sprite.palettePreset("user:<name>")`. Saved palettes
are never overwritten; each revision gets a new name.

## Layers, frames and the sheet sidecar

Wrap drawing calls in `sprite.beginLayer("shading")` and `sprite.endLayer()`
to keep outlines, base colors and shading editable independently. Layers flatten
into the final image in creation order. `sprite.size(w, h, frames)` creates a
horizontal strip of equal frames. `sprite.frame(i)` selects the frame to draw,
`sprite.frameDuration(i, ms)` sets pacing and `sprite.tag("walk", 0, 3)` names
frame ranges. Next to every strip PNG, Studio writes an Aseprite-compatible
`<name>.sheet.json` with frames, durations and tags. Open **Sprite Animation**
and import the sheet using its Aseprite import. Use `editor.tileset.create` for
tile sheets.

## Chat previews and verification

`editor.sprite.gif` renders a looping GIF from the sidecar or from explicit frame
dimensions. Set `firstFrame` and `lastFrame` to select an inclusive, zero-based
range. Save the preview beside the sheet or in `.ada/workspace/pixel-art/`. Use a
new filename for each export.

In native Studio chat, the A2UI `Image` component uses a project-relative path.
Show the GIF to check the loop or show the PNG strip to inspect all frames side
by side. The component uses nearest-neighbor filtering and integer zoom from 1
to 16. Omit `zoom` for automatic sizing. If the chat host does not support
`Image`, open the PNG in the asset panel. Hosts that advertise
`editor.image.read` can also inspect the PNG before adding it to the game.
