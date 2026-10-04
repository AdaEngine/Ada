# Immersive Garden (visionOS 26+)

A full immersive AdaEngine scene, with two offscreen 3D cameras presented through
Compositor Services. SwiftUI owns the floating tools window and immersive lifecycle;
AdaUI renders its controls through `AdaUIHost`. The original `GardenWorkspace` owns
scene editing, persistence and selection. AdaEngine owns the 3D scene and manipulation.

## Build

Requires Xcode with the visionOS SDK and XcodeGen:

```sh
cd Demos/ImmersiveGarden
xcodegen generate
open ImmersiveGarden.xcodeproj
```

Select the ImmersiveGarden scheme and an Apple Vision Pro. Set your signing team
in Xcode before installing on a device. Enter the garden from the tools window.
The immersive demo owns its scene construction and shares the committed assets
from SkeletalGarden. The desktop demo keeps its newer landscape, controller and
camera systems from main; changes from another dirty checkout are not required.

## Simulator

Select an Apple Vision Pro simulator in Xcode. Add `--enter-garden` to the scheme's
Run arguments for an automatic immersive entry (useful when UI automation cannot
resolve spatial window controls). Normal launches still use the Enter garden button.

The immersive layout puts animated models ahead of the viewer and the movable
crates near eye level. It is placed relative to the initial tracked head position,
using a nominal 1.6-meter eye height for the virtual floor. The desktop demo keeps
its original layout. Raw hand tracking and motion comfort require a physical device.

## Interaction

- Pinch near either crate to grab it. Move/rotate your hand to transform it.
- Add the other pinching hand to rotate and scale around the hands' midpoint.
- Release a hand to continue with the remaining hand. Releasing both drops the object.
- For distant objects, look and pinch: system spatial events provide the selection
  ray; no raw gaze tracking is requested.
- The tools window shows the selected object and position, adjusts scale, and saves
  or loads movable object transforms in `Documents/ImmersiveGarden.scene.json`.
- Leave the garden using the button or Digital Crown. Tracking loss releases a grip.

## Current limits and device acceptance

This is an initial integration, not a performance-qualified shipping VR renderer.
It disables foveation and serializes eye passes with asynchronous GPU fences because
current 3D passes share per-view uniform scratch. The main game simulation advances
once per displayed frame. A future multiview path can remove those fences.
Only root entities are supported for manipulation; rigid-body throwing, collisions,
world-anchored AdaUI panels and RemoteImmersiveSpace are future work. Panels here
are system SwiftUI windows. Capture-target drawables are not rendered yet.

Use real hardware to validate stereo orientation, head-motion stability, depth
occlusion of the tools window, direct/indirect selection, two-hand manipulation,
permission denial, tracking loss, Digital Crown dismissal and repeated reopening.
The simulator cannot establish hand-tracking quality or motion comfort.

Simulator smoke validation on visionOS 26.2 confirmed app launch, automatic
immersive entry, rendered models/crates/floor/sky, and the floating tools window.
It exposed and fixed a BGRA8/RGBA16F attachment mismatch, duplicate sRGB encoding,
and the missing input-Z mirror for native compositor projections. Spatial mouse
selection was not confirmed by the accessibility automation. The new projection
regression and the existing spatial interaction tests passed (10 focused tests).


## Embedded panel validation

The AdaUI tools panel is embedded in a SwiftUI window through `AdaUIHost`, with its
existing model shared with the immersive scene. Tests cover root updates preserving
local state/action closures and independent window managers. AdaUI + AdaRender
regressions passed (684 tests), and visionOS Simulator rendering was visually checked.
Actual Ada Studio panel composition remains in the Editor package; the runtime bridge
does not introduce a dependency on that executable into the engine.
