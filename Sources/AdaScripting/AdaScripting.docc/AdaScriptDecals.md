# Add 3D decals during gameplay

Use a decal to put a sticker, scuff or paint mark on the surface of a 3D
object. Place it on the entity that holds the opaque indexed PBR mesh.
For an animated model, pass its skinned mesh entity. A new decal samples
the current evaluated pose, then follows the surface as it moves.

## Place and check a decal

Pass a project image path, a world-space center and outward normal, and
the projector width, height and depth in world units. Group the three
vectors as `[point, normal, size]`. The image's alpha
channel controls coverage. The final argument is a list of optional
settings. Pass an empty list for an upright image with priority zero.

This example stamps a wall facing positive Z at the world origin. Tag
the wall with a component called Wall and import Paint.png into the
project's Textures directory.

```ada
@component(id: "example.wall")
struct Wall { @export var enabled = true; }

@system(id: "example.paint-wall")
class PaintWall {
    @query(Wall) var walls;
    var request = "";
    var handle = "";
    var finished = false;

    func update(context) {
        if (finished) { return; }
        if (request != "") {
            var result = context.world.decalResult(request);
            if (result == null) { return; }
            if (result.isSuccess()) {
                handle = result.value();
            } else {
                print(result.errorCode(), result.message());
            }
            finished = true;
            return;
        }
        for (var wall in walls) {
            request = context.world.placeDecal(
                wall.id, "@res://Textures/Paint.png",
                [[0, 0, 0], [0, 0, 1], [0.5, 0.5, 0.1]], []
            );
            break;
        }
    }
}
```

A request token identifies a queued operation. Poll it on a later
callback with decalResult. The call returns null while the operation is
pending and consumes the result when it finishes. Save the handle from a
successful placement before submitting another operation. A missing image,
unsupported receiver, missed projection or full queue produces an error
result. Check it with isSuccess(), errorCode() and message().

## Change or remove the decal

In a callback with the same world and mesh entity, call:

```ada
var change = context.world.updateDecal(wall.id, handle, "@res://Textures/Scuff.png", [1]);
var removal = context.world.removeDecal(wall.id, handle);
```

Poll each request as above. Updating changes the appearance of the same
footprint. The update settings are priority, normal-map path and
roughness-map path. Placement settings begin with rotation in degrees,
followed by those same three appearance settings. Use null for a skipped
setting before another value. Larger priorities draw over smaller ones.

A decal handle belongs to its world and receiver. Removing the receiver
or replacing its mesh invalidates the handle. The renderer allows up to
eight decals per receiving mesh, including any placed in Studio.

The interpreted and native compiled script paths use the same native
SAGA raster renderer. Browser WebGPU and headless runtimes cannot place
these decals. Path-traced views do not display them.
