---
name: ada-pixel-art
description: Draw pixel-art sprites, animated strips, icons and tile sheets as PNG files from an AdaScript program in Ada Studio, keep the style consistent with locked palettes and layers, preview results in chat, and turn them into atlases, tilesets and sprites. Triggers include pixel art, sprite, sprite sheet, walk cycle, animation frames, tileset, retro game art, palette, PICO-8, GameBoy, NES colors, 8-bit, 16x16, 32x32.
allowed-tools: editor.project.context, editor.file.read, editor.file.write, editor.file.patch, editor.sprite.generate, editor.palette.extract, editor.sprite.gif, editor.image.read, editor.atlas.pack, editor.tileset.create, editor.tileset.read, editor.tilemap.write, editor.components.describe, editor.scene.get, editor.scene.apply, editor.docs.read, editor.build.start, editor.play.start, editor.task.status
---

# Ada Studio Pixel Art

Use this for 2D game art you can build from shapes on a small grid: characters, enemies, items, icons, particles, UI pieces and tile sheets, still or animated. Describe the picture in AdaScript and Studio writes a `.png`. Painted or photographic art needs the image generation provider (`editor.image.generate`) when one is configured; otherwise stay in pixel-art style.

The saved-recipe and GIF workflow below is available in native Studio. In browser Studio, pass the script and destination directly to the sprite generator, then open the PNG in the asset panel.

## Discipline (mandatory)

1. **Palette first** — choose a palette preset (or extract one from the user's reference art) before drawing any pixel. Every pixel uses only palette colors.
2. **Size and palette before pixels** — lock the canvas size and the palette, then draw. Re-read both before each new sprite of the same game; one game keeps one palette so the art matches.
3. **One asset at a time** — finish, inspect and fix one sprite before starting the next.
4. **No anti-aliasing** — every pixel is fully opaque or fully transparent; no soft edges, no blur, no gradients (dither instead).
5. **Look before done** — check the result with `editor.image.read` or a chat preview and fix what is wrong. Never call a sprite finished from pixel counts alone.

## Workflow

1. Read `editor.project.context` for the Assets root. Choose a new destination such as `Assets/Sprites/hero.png`; `editor.sprite.generate` never overwrites, so use a new name for each revision.
2. Keep the build script as a **recipe file**: write it to `.ada/workspace/pixel-art/<name>.adas` with `editor.file.write`, then call `editor.sprite.generate` with its text as `source`, the destination, and the recipe path as `recipe` (it is recorded in the sheet metadata). For a revision, `editor.file.patch` the recipe and generate again under a new destination name — patch the saved recipe instead of rewriting the script from scratch.
3. The script runs in an isolated VM: no files, network, scene or engine access, a 64 KiB source limit and a small time/step budget. Errors come back as text; fix the recipe and call again.
4. Inspect the result in the asset panel or with the chat preview. If the host advertises `editor.image.read`, use it with a precise question ("Does this read as a red slime facing front? What looks wrong?"). Patch the recipe and regenerate as needed.
5. For animation, render a looping preview with `editor.sprite.gif` and show it in chat (see Chat preview). For a still, show the PNG the same way.
6. Use the PNG with a `Sprite` component. Open the generated `<name>.sheet.json` through the Sprite Animation editor's Aseprite import to use its frames, durations and tags. For a tile sheet of equal cells, use `editor.tileset.create`. Read `editor.components.describe` with query `Sprite`, preserve unrelated payload fields and pass the current scene revision.
7. Build, run visible Play and inspect a frame at the size the sprite is shown. Check scale, anchor and draw order, and that the pixels stay sharp: if they look blurry, set the texture's sampler filter to nearest in its texture settings.

## Script API

Define `func build(sprite)`. Coordinates are whole pixels, `(0, 0)` is the top-left corner, x grows right and y grows down. Color `0` is transparent and also erases. A failed call records the error and generation is rejected with that message.

| Call | Meaning |
| --- | --- |
| `sprite.size(w, h)` | Canvas size, 1...512 per side. Call it first, once. |
| `sprite.size(w, h, frames)` | A horizontal strip of `frames` equal cells (at most 64 frames, strip width at most 512). Unlocks `frame`, `frameDuration` and `tag`. |
| `sprite.palettePreset(name)` | Load a bundled palette (`"pico-8"` etc., see Palettes) or `"user:<name>"` for one saved by `editor.palette.extract`. Entries fill indices 1...N in the listed order. Works before `size`. |
| `sprite.palette(i, r, g, b)` | Palette entry `i` (1...255), channels 0...255. Unset entries are magenta so mistakes are visible. |
| `sprite.opacity(i, a)` | Alpha 0...255 of a palette entry, for shadows and glass. |
| `sprite.pixel(x, y, c)` | One pixel. Outside the canvas is ignored. |
| `sprite.rect(x0, y0, x1, y1, c)` | Filled rectangle, corners inclusive. |
| `sprite.line(x0, y0, x1, y1, c)` | Line. |
| `sprite.ellipse(cx, cy, rx, ry, c)` / `sprite.circle(cx, cy, r, c)` | Filled ellipse or circle around a pixel. |
| `sprite.fill(c)` | Fill the whole canvas. |
| `sprite.mirror()` | Copy the left half onto the right half, mirrored: draw half a character and get a symmetric one. |
| `sprite.outline(c)` | Paint `c` on every transparent pixel next to a painted one. Do it last. |
| `sprite.colorAt(x, y)` | Palette index at a pixel of the current frame, layers merged, for loops and checks. |
| `sprite.beginLayer(name)` / `sprite.endLayer()` | Draw on a named layer stacked above the base; see Layers. |
| `sprite.frame(i)` | Select frame `i` (0-based) of a strip; later drawing goes to that frame. |
| `sprite.frameDuration(i, ms)` | Milliseconds frame `i` stays on screen (default 100). |
| `sprite.tag(name, from, to)` | Name an inclusive frame range such as `"walk"`, written to the sheet metadata. |

Later calls overwrite earlier ones: paint large shapes first and details last.

## Palettes

`sprite.palettePreset("pico-8")` fills palette indices 1...N in the order listed. Pick one palette per game and keep it.

| Preset | Colors | Best for |
| --- | --- | --- |
| `pico-8` | 16 | Game jams, tiny games, fantasy console |
| `sweetie-16` | 16 | Cute or pastel worlds |
| `gameboy` | 4 | Monochrome retro, darkest to lightest |
| `cga` | 16 | PC retro |
| `commodore-64` | 16 | C64-style games |
| `db32` | 32 | General indie, the most versatile |
| `endesga-32` | 32 | Vibrant colorful worlds |
| `nes` | 56 | Classic 8-bit console hardware |
| `snes` | 64 | 16-bit era games |
| `resurrect-64` | 64 | Complex detailed environments |

- `cga` (16): #000000 #0000AA #00AA00 #00AAAA #AA0000 #AA00AA #AA5500 #AAAAAA #555555 #5555FF #55FF55 #55FFFF #FF5555 #FF55FF #FFFF55 #FFFFFF
- `commodore-64` (16): #000000 #FFFFFF #880000 #AAFFEE #CC44CC #00CC55 #0000AA #EEEE77 #DD8855 #664400 #FF7777 #333333 #777777 #AAFF66 #0088FF #BBBBBB
- `db32` (32): #000000 #222034 #45283C #663931 #8F563B #DF7126 #D9A066 #EEC39A #FBF236 #99E550 #6ABE30 #37946E #4B692F #524B24 #323C39 #3F3F74 #306082 #5B6EE1 #639BFF #5FCDE4 #CBDBFC #FFFFFF #9BADB7 #847E87 #696A6A #595652 #76428A #AC3232 #D95763 #D77BBA #8F974A #8A6F30
- `endesga-32` (32): #BE4A2F #D77643 #EAD4AA #E4A672 #B86F50 #733E39 #3E2731 #A22633 #E43B44 #F77622 #FEAE34 #FEE761 #63C74D #3E8948 #265C42 #193C3E #124E89 #0099DB #2CE8F5 #FFFFFF #C0CBDC #8B9BB4 #5A6988 #3A4466 #262B44 #181425 #FF0044 #68386C #B55088 #F6757A #E8B796 #C28569
- `gameboy` (4): #0F380F #306230 #8BAC0F #9BBC0F
- `nes` (56): #7C7C7C #0000FC #0000BC #4428BC #940084 #A80020 #A81000 #881400 #503000 #007800 #006800 #005800 #004058 #000000 #000000 #000000 #BCBCBC #0078F8 #0058F8 #6844FC #D800CC #E40058 #F83800 #E45C10 #AC7C00 #00B800 #00A800 #00A844 #008888 #000000 #000000 #000000 #F8F8F8 #3CBCFC #6888FC #9878F8 #F878F8 #F85898 #F87858 #FCA044 #F8B800 #B8F818 #58D854 #58F898 #00E8D8 #787878 #000000 #000000 #FCFCFC #A4E4FC #B8B8F8 #D8B8F8 #F8B8F8 #F8A4C0 #F0D0B0 #FCE0A8
- `pico-8` (16): #000000 #1D2B53 #7E2553 #008751 #AB5236 #5F574F #C2C3C7 #FFF1E8 #FF004D #FFA300 #FFEC27 #00E436 #29ADFF #83769C #FF77A8 #FFCCAA
- `resurrect-64` (64): #2E222F #3E3546 #625565 #966C6C #AB947A #694F62 #7F708A #9BABB2 #C7DCD0 #FFFFFF #6E2727 #B33831 #EA4F36 #F57D4A #AE2334 #E83B3B #FB6B1D #F79617 #F9C22B #7A3045 #9E4539 #CD683D #E6904E #FBB954 #4C3E24 #676633 #A2A947 #D5E04B #FBFF86 #165A4C #239063 #1EBC73 #91DB69 #CDDF6C #313638 #374E4A #547E64 #92A984 #B2BA90 #0B5E65 #0B8A8F #0EAF9B #30E1B9 #8FF8E2 #323353 #484A77 #4D65B4 #4D9BE6 #8FD3FF #45293F #6B3E75 #905EA9 #A884F3 #EAADED #753C54 #A24B6F #CF657F #ED8099 #831C5D #C32454 #F04F78 #F68181 #FCA790 #FDCBB0
- `snes` (64): #000000 #1F0E3C #3C1361 #5B1E8C #7B2FB5 #9B44D8 #B76AE8 #D39AF5 #0D1B47 #1A3370 #2B5098 #3F72BF #5A97DC #7BBCE8 #A3D9F5 #D0EFFC #0A2E1A #145C33 #1F8A4B #2DB566 #47D87F #6FE89A #99F2B8 #C5F9D8 #3C1A00 #6B3010 #9A4A20 #C46830 #E88A45 #F5AD6A #FACA90 #FDE4C0 #3C0000 #6B0000 #9A0000 #C40000 #E82020 #F55050 #FA8080 #FCC0C0 #3C3C00 #6B6B00 #9A9A00 #C4C400 #E8E820 #F5F550 #FAFA80 #FCFCC0 #3C003C #6B006B #9A009A #C400C4 #E820E8 #F550F5 #FA80FA #FCC0FC #1A1A1A #333333 #4D4D4D #666666 #808080 #999999 #B3B3B3 #FFFFFF
- `sweetie-16` (16): #1A1C2C #5D275D #B13E53 #EF7D57 #FFCD75 #A7F070 #38B764 #257179 #29366F #3B5DC9 #41A6F6 #73EFF7 #F4F4F4 #94B0C2 #566C86 #333C57

**User palettes.** When the user provides reference art, call `editor.palette.extract` with the image path under Assets, a short `name` and optionally `maxColors` (default 16). It saves a user palette; load it with `sprite.palettePreset("user:<name>")`. Palette names are never overwritten — pick a new name per revision.

## Layers

Layers stack transparent sheets above the base drawing; the PNG flattens them in creation order. Use them like an editor's layers: base body on the default layer, then `sprite.beginLayer("face")` ... `sprite.endLayer()` for the face, `"equipment"` for gear. Calling `beginLayer` with an existing name clears that layer and redraws it, so a revision can redo one part without touching the rest. At most 16 layers. `mirror`, `outline`, `fill` and shapes apply to the current layer of the current frame.

## Animation strips

`sprite.size(w, h, frames)` creates a horizontal strip of equal frames. Select each frame with `sprite.frame(i)` and draw it; set pacing with `sprite.frameDuration(i, ms)` and name ranges with `sprite.tag("walk", 0, 3)`. Studio writes an Aseprite-compatible `<name>.sheet.json` next to the PNG, so slicing, tags and durations survive import. Typical pacing: idle 2-4 frames at 6-8 fps, walk 4-6 at 8-12, run 6-8 at 12-16, attack 4-6 at 12-16, death 4-6 at 6-10. Check that the first and last frame loop cleanly. Preview with `editor.sprite.gif`: it reads the sidecar automatically and renders a looping GIF at an integer `scale` (4 is a good chat size).

## Craft

- Pick the size for how big the sprite appears: 16 px for small tiles and items, 32 px for characters, 8 px for particles and bullets. Draw at the final size; do not scale up later.
- Work with 4-8 colors per sprite even from a larger palette: a base, a darker shade for the underside, a lighter one for the highlight, plus a very dark outline. Keep the light source at the top right for every asset.
- Use `sprite.mirror()` for anything symmetric, and loops for repeating details (bricks, grass, windows).
- A tile sheet is one canvas of equal cells: draw each tile in its cell with a loop over cell offsets, keep edges seamless where tiles meet (match the pixels on opposite borders), then call `editor.tileset.create` with the cell size. Avoid centered symmetric patterns in terrain; favor roughly 70% base color, 15% dark accent, 10% light accent, 5% rare feature pixels.
- Only the calls above exist; do not use `print`, files, imports or `System`. A script that fails validation is rejected before running.

## Chat preview

Show the user the result as an A2UI surface with an `Image` component in native Studio. Use a PNG for a still or a contact sheet, and the GIF from `editor.sprite.gif` for playback. Set `firstFrame` and `lastFrame` for a zero-based inclusive range. `path` is project-relative and `zoom` is an integer nearest-neighbor scale. On hosts without `Image` support, open the PNG in the asset panel and tell the user where it is.

```a2ui
{"version":"v0.9.1","createSurface":{"surfaceId":"sprite-preview-slime","catalogId":"https://adaengine.org/a2ui/catalogs/forms/v1","sendDataModel":false}}
{"version":"v0.9.1","updateComponents":{"surfaceId":"sprite-preview-slime","components":[{"id":"root","component":"Column","children":["title","image"]},{"id":"title","component":"Text","text":"slime.gif — 3 frames, 120 ms, gameboy"},{"id":"image","component":"Image","path":"Assets/Sprites/slime.gif","zoom":4}]}}
```

## Examples

A still sprite with a preset palette and a separate face layer:

```
func build(sprite) {
    sprite.size(16, 16);
    sprite.palettePreset("pico-8");       // 1=black, 9=red, 12=green
    sprite.ellipse(7, 10, 7, 5, 12);      // body on the base layer
    sprite.rect(0, 11, 15, 14, 12);
    sprite.beginLayer("face");
    sprite.pixel(4, 9, 1);
    sprite.pixel(11, 9, 1);
    sprite.rect(6, 12, 9, 12, 9);
    sprite.endLayer();
    sprite.outline(1);
}
```

A three-frame walk strip with pacing and a tag:

```
func build(sprite) {
    sprite.size(8, 8, 3);
    sprite.palettePreset("gameboy");      // 1=darkest green
    var i = 0;
    while (i < 3) {
        sprite.frame(i);
        sprite.ellipse(3, 4, 3, 3, 1);
        sprite.pixel(2, 7, 1);
        sprite.pixel(4 + i, 7, 1);
        i = i + 1;
    }
    sprite.frameDuration(0, 120);
    sprite.frameDuration(1, 120);
    sprite.frameDuration(2, 120);
    sprite.tag("walk", 0, 2);
}
```
