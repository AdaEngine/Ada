# Pipelined Rendering

Render a scene one frame behind its simulation to overlap rendering with the next frame's work.

## Overview

By default a frame runs every world in sequence: the scene simulates, extracts its renderable state,
renders, and only then can the window's UI and the next frame start. With pipelined rendering, the
scene's render world draws frame N while the simulation and UI already prepare frame N+1. Extraction is
the only point where the two meet: before extracting frame N+1, the engine waits for frame N to finish.

A frame then takes about as long as the slower of the two paths instead of their sum. The cost is one
frame of input latency, about 7 ms on a 143 Hz display. Pipelining does not reduce GPU time: when the GPU
is already the limit, the frame rate does not change.

Enable it for a `SceneView`:

```swift
SceneView(useSceneCameras: true, make: { app in
    app.addPlugin(RenderWorldPlugin())
    // ...
}, updateContent: { _, _ in })
.pipelinedRendering()
```

Or for any render world you manage yourself:

```swift
renderWorld.insertResource(RenderPipelining(isEnabled: true))
```

Set `ADAENGINE_PIPELINED_RENDERING=0` or `=1` to override the setting of every world that declares it,
for example to compare both modes. WebAssembly builds always render serially.

## Rules for scene code

While a frame is in flight, the simulation and the renderer run at the same time. Two rules keep them
apart:

- **Render systems read the scene only during extraction.** Use `Extract` parameters only in systems
  registered on the `.extract` schedule, and copy what later schedules need into render-world resources.
  The `MainWorld` reference is removed after extraction; debug builds assert when `Extract` is read later.
- **Do not mutate assets in place while they are rendered.** The renderer draws a snapshot of each
  `PBRMaterial` taken at extraction, so material edits are safe and appear one frame later. Other assets
  such as meshes and textures should be replaced, not edited in place, while a frame may be rendering them.

Tooling entry points such as `AppWorlds.withWorldAccess(_:)` wait for the frame in flight before they run.
Render statistics resources are synchronized and can be read at any time.

## Measuring

Run with `ADAENGINE_STALL_PROBE=1` to print slow operations, including `App.Update.*` and `Schedule.*`
spans for each world. With pipelining on, the scene's update on the main thread shrinks to its simulation
and extraction while its render world appears as a separate span. The Sponza technical example also
prints per-second frame statistics with `ADAENGINE_SPONZA_FRAME_LOG=1`.
