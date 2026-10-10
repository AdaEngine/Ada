# Sprite layout and tile orientation

Select a Sprite in the scene Inspector to edit its **Anchor**, **Anchor X / Y**
and **Image Mode**. Anchors are normalized, with `(0, 0)` at the center and
positive Y pointing up. Presets cover the center, corners and edge centers;
custom coordinates may be outside the sprite. Flipping the texture does not move
the anchor.

Image modes are `stretch`, centered aspect `fit` / `fill`, `sliced` (nine-slice)
and `tiled`. Slice controls use source pixels in top/left/bottom/right order.
Tiled controls choose the repeated axes and the number of world units per source
pixel. Borders must be nonnegative and tile scale must be positive and finite.
Only the controls belonging to the active image mode appear.

Inspector edits use the normal scene document history, Save and Play paths.
Existing scenes without layout fields remain centered and stretched. The scene
payload retains the runtime `SpriteAnchor` / `SpriteImageMode` Codable format.

## AdaScript

The same layout can be authored through the registered Sprite constructor:

```adascript
@system class CreatePanel {
    func update(context) {
        context.world.spawn([
            Transform(position: Vector3.ZERO),
            Sprite(
                texture: "@res://panel.png",
                size: [160, 80],
                anchor: SpriteAnchor.bottomLeft,
                imageMode: SpriteImageMode.sliced(SpriteSliceBorder(8, 12, 8, 12))
            )
        ]);
    }
}
```

`SpriteAnchor(x, y)` constructs a custom anchor. Other modes are
`SpriteImageMode.stretch`, `.fit`, `.fill` and
`SpriteImageMode.tiled(tileX, tileY, scale)`. Factory arguments use positional
syntax; Sprite arguments support names. Queries can assign `sprite.anchor`,
`sprite.size` and `sprite.imageMode` using the same detached values. A null size
restores the texture's natural size. Invalid values are rejected.

The VM and native host share layout factories and constructor conversion. This
does not expand the embedded Web Player's restricted scene-component catalog.

## Tile maps

The tile-map Inspector's **Orientation** section controls the brush, plus the
selected cell when using Select. Eight choices rotate in 90-degree increments
or mirror X before rotating. Repainting the same tile can change its orientation.
The canvas previews orientations inside the original cell, including rectangular
tiles. Layers keep independent choices. Palette removal preserves the orientation
of surviving cells; old three-integer cells default to Original.

Saved palette cells use `[x, y, paletteIndex, orientationID]`, where the optional
fourth integer is 0...7. The production tile-map loader uses these values for
images and shadow occluders. Editing unrelated cells preserves existing values.

AdaScript can enqueue a change to an existing scene tile:

```adascript
@system class RotateTiles {
    @query(TileMapComponent) var maps;
    func update(context) {
        for (var entity in maps) {
            context.world.setTileOrientation(entity.id, 0, [2, 3], TileOrientation.mirrorXRotate90);
        }
    }
}
```

`world.commands.setTileOrientation` provides the same operation. Its Boolean
result reports whether the command was accepted; the target is checked when the
deferred queue executes. Missing targets/layers produce diagnostics; empty cells
are unchanged. The map is a shared asset, so all owners observe a change. Runtime
changes do not save the authored resource on disk.

## Validation — 2026-10-09

Engine regression: 186 tests in 36 suites. Editor regression: 60 tests in eight
suites, including real AdaUI menu/text/pointer controls, fractional values,
scene history and resource round trips. A standalone AOT C smoke checks factory
values. Editor tests/build and the macOS Studio launch used a temporary source
snapshot with this task's Editor changes and the current engine, because unrelated
Community publishing changes blocked the shared checkout. The native process
remained running with a temporary project; its visual layout was not inspected.
Physical mobile-device and browser authoring behavior remain unverified.
