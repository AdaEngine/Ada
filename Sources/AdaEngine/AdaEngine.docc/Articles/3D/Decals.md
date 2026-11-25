# 3D Decals

Use `Decal3D` to stamp an image onto an opaque 3D mesh. The image moves
with the mesh. A stamp on an animated model deforms with the surface,
including across a joint, and can be placed while that joint is bent.

## Place a decal in Ada Studio

Open a 3D scene in the desktop editor and select **Decals** in the viewport
toolbar. In the Inspector, choose a project image and select **Place decal**.
Point at an opaque mesh, then click the surface to apply the image.
Press Escape to exit placement. Select **Done** to close the tool.

Select the receiving object and choose a decal in its Inspector list.
Change its image, width, height, depth, rotation or priority. Use **Move**
to choose a new spot on the same object. **Delete** removes the selected
decal. Undo and Redo work with scene history. Save the scene to keep the
decals when reopening it, playing it or exporting it for a native target.

Studio places decals on primitives and static or rigid meshes of imported
models. Skinned and morphed receivers are available through the gameplay APIs
below. The visual tool uses native SAGA raster rendering.

## Stamp a moving car

Call `Decal3D.place` on the main actor after the receiving entity has
joined the scene. Pass the entity that holds `Mesh3DComponent`. If a car's
physics body is the parent of its bodywork mesh, pass the bodywork entity.

```swift
import AdaEngine

@MainActor
func applySticker(to bodywork: Entity, frame: Transform3D, artwork: Image) throws -> Decal3D.Handle {
    try Decal3D.place(
        on: bodywork,
        projector: .init(transform: frame, size: [0.45, 0.25, 0.10]),
        appearance: .init(color: artwork)
    )
}
```

The frame is the decal's world-space position and orientation. Its local
negative Z axis points toward the surface and positive Y points toward
the top of the image. The size gives the full width, height, and depth.
Use a shallow depth to reach the intended surface. To restrict the stamp
to a specific mesh part, pass its ID as `part:`.

A physics raycast can supply an approximate hit position and normal.
Use a frame with its positive Z axis aligned with the hit normal. The
placement call checks the render mesh for actual coverage and throws
`Decal3D.PlacementError.missesReceiver` if the volume misses.

## Stamp a character

Pass the skinned mesh entity, such as the part holding the character's
shirt, and call the same `applySticker` function after animation and
transform evaluation. A placement samples the current evaluated pose.
The same portion of the shirt then carries the stamp through subsequent
poses. The shader uses the stamp's own coordinates, so the model's
material UVs can be shared or mirrored.

While a skinned or morphed mesh carries a decal, it draws the source
topology to preserve the stamp's attachment. Removing its last decal
restores the normal mesh LOD selection. Replacing the mesh discards its
attachments. If an alternative mesh changes or cannot represent a stamp,
the receiver uses its source mesh until the decals are removed.

## Change a stamp

Keep the returned handle to update or remove a decal from the same entity.
A larger priority draws on top of smaller priorities. Equal priorities
draw in creation order. Saved scene decals draw before gameplay decals of
the same priority, including when a scene image finishes loading later.

```swift
try Decal3D.update(sticker, on: bodywork, appearance: .init(color: newArtwork, priority: 1))
try Decal3D.remove(sticker, from: bodywork)
```

The image's alpha controls coverage. You can also supply a linear
tangent-space normal image and a linear roughness image using its red
channel. Alpha blends those channels into the existing material before
the lighting calculation.

## Limits

Decals use the native SAGA raster path and standard opaque PBR materials
on indexed triangle meshes. Browser WebGPU and headless backends return
`unsupportedBackend`. Decal rendering is available in the raster view.
Swift and AdaScript can also place decals during scene setup or gameplay.

A receiver can hold eight decals. All active images for a receiver must
fit a 2048 × 2048 atlas. Placement and expanded mesh storage also have
bounded budgets. When a placement or appearance update exceeds its budget,
it throws `capacityExceeded` and keeps the receiver's existing decals.
Decals require geometry whose render buffers still match its mesh
descriptor. A direct edit to those buffers invalidates existing stamps.
