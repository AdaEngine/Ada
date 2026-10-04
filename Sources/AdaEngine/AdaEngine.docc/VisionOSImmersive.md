# visionOS Immersive Rendering

Use `AdaEngineEmbeddable` from a SwiftUI visionOS application to display an AdaEngine
world in a full immersive space. `Demos/ImmersiveGarden` contains a runnable host.

Create an `ImmersiveSpace` containing a `CompositorLayer` configured with
`ImmersiveLayerConfiguration`. In the layer's callback, start a main-actor task,
create `AdaImmersiveRenderer`, and await its `run(setup:)`. Instantiate scene models
in `setup`, after renderer plugins and asset loading are ready. Keep and cancel the
task when the immersive space closes. `performWorldAccess` queues inspector edits
between frames; do not mutate the world from arbitrary SwiftUI callbacks.

The host converts ARKit world poses to Ada's +Z-forward coordinates and uses the
compositor's asymmetric per-eye projections. Native projections accept right-handed
view-space input, so the host explicitly mirrors input Z before adapting their depth;
the compositor's NDC convention alone does not convert camera handedness. Ada's offscreen pipelines use forward
Z; the final Metal pass converts depth back to reverse Z for system composition.
The host uses the engine's Metal command queue to preserve GPU resource ordering.

`SpatialGrabbable` marks root entities with local bounds. `SpatialInput` provides
active grip poses and optional selection rays. `SpatialInteractionSystem` updates
transforms and publishes `SpatialSelection` for inspectors. The platform-independent
interaction path can be tested without ARKit or a headset.

The initial host requires visionOS 26, disables foveation, and serializes its eye
passes. It is intended for functional device validation before multiview and frame
latency optimization. It does not yet render capture-target drawables.

## Reuse AdaUI panels in spatial windows

SwiftUI owns window scenes and immersive presentation. Existing AdaUI panels keep
their view models, `@State`, bindings, input handling and rendering inside `AdaUIHost`
from `AdaEngineEmbeddable` (UIKit platforms, including visionOS).

Inside a visionOS editor target, an existing panel can be composed as follows:

```swift
SwiftUI.WindowGroup(id: "inspector") {
    AdaUIHost(assetBundle: .module) {
        EditorInspectorSidebar(viewModel: sharedInspectorViewModel)
    }
}
```

Add the `AdaEngineEmbeddable` product to that target's dependencies. Share the same
editor view model with the scene and other panels; do not mirror editor state into
a second SwiftUI implementation. The host reconciles updated root content while
retaining AdaUI local state and node identity. It owns a separate input/window
manager, acquires only its own drawable, and stops when SwiftUI dismantles the view.

`ImmersiveGarden` demonstrates this split with an AdaUI tools panel and the original
`GardenWorkspace`. This validates the bridge; it does not yet port the full Ada Studio
application or all native panel controls to visionOS.
