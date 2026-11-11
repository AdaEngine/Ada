# Pipelined Rendering

Status: Approved; implementation in progress.
Approval: explicit user approval in this Claude Code conversation on 2026-11-09 ("ok, sounds good. I approve it."),
including decisions D1–D5 as written.
Date: 2026-11-09.
Classification: improvement of an existing subsystem (the `AppWorlds` frame loop and the render world).
Evidence: [Sponza load, pacing and binding cost](../Performance/SponzaLoadAndPacing-2026-11-09.md).
Proposed follow-up: [Incremental mesh extraction and directional cascades](incremental-mesh-extraction-and-cascades.md).

## 1. Problem

A frame runs every world one after another on the main actor. In the Sponza demo the scene's render world
waits for the scene simulation, and the UI window waits for the scene's render world:

| Sponza heavy view, 1890×784 scene, flying light off, 0 local lights | CPU per frame |
| --- | ---: |
| UI window: layout and simulation systems | 0.8 ms |
| SceneView: simulation systems + extraction | 0.9 ms |
| SceneView render world (render graph, encoding, Dawn submit) | 7.8 ms |
| UI window: extraction + render world | 1.8 ms |
| **Total, serial** | **~11.4 ms (87 FPS)** |

The display runs at 143 Hz (7.0 ms per frame). The render world alone fits in that budget, but together
with everything else it does not. The GPU is not the limit at this size.

This design does not cover per-pixel GPU cost. At full screen (3810×1684) the GPU is busy 96–100% of the
time, and pipelining does not help there. That needs separate work (§9).

## 2. Decision

Run a render world **one frame behind** its main world, on its own executor:

```
main thread:  [sim N] [extract N] [sim N+1] [extract N+1] [sim N+2] ...
render world:          [render N ..........] [render N+1 .........]
```

- Extraction is the only point where the two worlds meet. Before extracting frame N+1, the main world waits
  for render N to finish, then extracts, then starts render N+1 without waiting for it. This is the model
  Bevy uses ("pipelined rendering").
- Frame time becomes about `max(main path, render path)` instead of their sum. For the Sponza view above,
  that is about max(3.5, 7.8) = **7.8 ms (~128 FPS)** instead of 11.4 ms.
- Reaching 143 FPS there also needs the render path below 7 ms (§8).
- Pipelining is **opt-in per render world** in the first version.

## 3. Goals and non-goals

| ID | Goal |
| --- | --- |
| G1 | With pipelining on, frame time is close to max(main path, render path), not their sum. |
| G2 | Same images as serial rendering, one simulation frame later. No tearing between the main world and the render world. |
| G3 | No data race between main-world systems and a render world in flight. This is checked, not assumed (§5). |
| G4 | Tooling (`withWorldAccess`, `withExclusiveWorldAccess`), resize, scene changes and shutdown wait for the render world in flight. |
| G5 | Serial mode stays the default and behaves exactly as today. |

Non-goals:
- Running render graph nodes in parallel with each other.
- Multithreaded command encoding.
- Reducing GPU time.
- Frame generation.
- Pipelining on WebAssembly, which is single-threaded; there the setting is ignored.

## 4. Behavior

### 4.1 Frame loop

`AppWorlds.updateFrameContents()` keeps today's order for serial subworlds. For a pipelined subworld:

1. Run the main schedule (unchanged).
2. `await` the previous render task of that subworld (normally already finished).
3. Run extraction on the main actor, exactly as today.
4. Start `world.update()` as a child task on the subworld's render executor. Store the handle and do not await it.
5. Continue with the other subworlds and the end of the frame.

The subworld's render executor is a serial executor owned by that render world (§4.3).

The window swapchain is presented inside its render task, as today in `RenderSystem`. The SceneView keeps
publishing the newest *completed* frame. Its render-target ring already holds `maxFramesInFlight + 2`
textures, which covers one extra frame in flight.

### 4.2 Safe points

The following wait for the render world in flight before they run:
- `withWorldAccess`, `withExclusiveWorldAccess` and `withHostedUpdatesSuspended`
- `removeSubworld`, SceneView retargeting and resize
- application termination

The wait is an `await` on the stored task, so the main actor stays free for other work while it waits.

### 4.3 Executors

Today every render graph runs on the single global `RenderGraphActor`. If the scene's graph is in flight,
the UI window's graph would queue behind it, which serializes the two again.

- Each pipelined render world gets its own serial executor.
- `RenderGraphActor` stays as the default for serial worlds.
- Concurrent encoding from two executors is already safe: WebGPU and Dawn calls go through
  `webGPUDeviceLock`, and Metal command buffers are thread-safe per encoder.

### 4.4 Latency

Input reaches the screen **one frame later** than in serial mode: about 7 ms at 143 Hz. This is the
inherent cost of pipelining and the reason it is opt-in.

### 4.5 Configuration

```swift
renderWorld.insertResource(RenderPipelining(isEnabled: true))   // per render world
SceneView(..., pipelinedRendering: true)                         // SceneView convenience
```

- `ADAENGINE_PIPELINED_RENDERING=0|1` overrides the setting for measurements.
- The Sponza demo enables pipelining for its SceneView. The UI window's own render world stays serial.

## 5. Isolation rules (the main risk)

Serial mode hides shared mutable state between the worlds. Pipelining makes that state race. The audit for
this design found these categories:

| ID | Shared state | Today | Required under pipelining |
| --- | --- | --- | --- |
| R1 | `MainWorld` resource in the render world | Inserted at extraction and kept for the whole render frame | Removed after the `.extract` schedule. Reading it later fails a debug assertion. |
| R2 | `Extract<T>` system parameter | Reads the main world in **any** schedule where its system runs | Allowed only in `.extract`. Elsewhere it is a debug assertion and returns the values from the last extraction. Every current use is audited and moved. |
| R3 | Reference-type assets read during rendering (`PBRMaterial` properties and texture references, `Mesh` parts, `Texture2D`) | Main-world systems may mutate them between frames | Materials: extraction takes an immutable snapshot (`PBRMaterialState`, value type, textures retained) and the render path reads only the snapshot. Meshes and textures: replaced, never mutated in place, while referenced by an extracted item; audit the procedural paths (terrain, voxel meshing, morphs). |
| R4 | Render → main feedback (`Render3DMeshletStatistics`, `Render3DTemporalStatistics`, picking readbacks, `onFrameRendered`) | Plain properties read on the main actor | Locked (`Mutex`) or delivered on the main actor through completion. |
| R5 | `@MainActor` systems registered in a render world (camera, window layout) | Run on the main actor during the render frame | Not allowed in a pipelined render world: they move to `.extract` or the world refuses to enable pipelining, with a logged reason. |
| R6 | Asset loading and GPU uploads on the main thread | Serialized with rendering | Already safe through `webGPUDeviceLock` and Metal's thread-safe queue. No change. |

A pipelined render world **refuses to enable** (logs and stays serial) when it finds a known-unsafe
registration (R5). R1 and R2 are enforced with debug assertions. Strict concurrency checking cannot
enforce R3, because `World` and `Material` are `@unchecked Sendable`. Tests cover R3 instead (§7).

## 6. Alternatives considered

| Alternative | Why not |
| --- | --- |
| Overlap only the scene render with the UI render (no simulation overlap) | Saves only ~1.8 ms; the render world still waits for the simulation. |
| Multithreaded command encoding inside Main3D | WebGPU allows one encoder per pass. Dawn serializes behind one device lock. Large change for less gain. |
| Dawn `skip_validation` / `disable_robustness` | About −1 ms. Useful on top, but cannot reach 7 ms alone, and trades safety. Kept as a separate, release-only option (§8). |
| Lower internal resolution | Addresses GPU time only; this design is about CPU. Tracked separately (§9). |
| Pipelining always on | +1 frame of latency and the R3 constraints on every game; too large a behavior change for a first version. |

## 7. Acceptance criteria

1. **Speed, mid-size window.** In the Sponza heavy view at 1890×784, flying light off, 0 local lights, the
   median frame time is ≤ 8.0 ms with pipelining (11.4 ms today). With the §8 render-path work as well,
   it is ≤ 7.0 ms (143 FPS).
2. **Hitches.** With autopilot motion, no frame is longer than 33 ms after warmup.
3. **Same images.** WebGPU golden-frame tests produce the same images with pipelining on, rendering a fixed
   simulation state.
4. **R1/R2.** A test asserts that `MainWorld` and `Extract<T>` are unavailable after `.extract` in a
   pipelined world.
5. **R3.** A test mutates a material's factor and texture every frame while rendering is in flight. Each
   frame renders exactly one snapshot, and the race-detection run is clean. On macOS the run uses the
   Thread Sanitizer; on Windows, stress iterations plus the snapshot checks.
6. **Safe points.** Tests cover `withWorldAccess` during a render in flight, SceneView resize, subworld
   removal and shutdown: no crash and no frame lost.
7. **Serial mode unchanged.** The existing suite passes with pipelining off.

## 8. Render-path budget (needed for 143 FPS, separate tasks)

The render path is 7.8 ms today. Candidate reductions, each measured on its own:

| Item | Measured or estimated |
| --- | ---: |
| Release-only Dawn `skip_validation` (validation stays on in debug builds and tests) | −0.5 to −1.0 ms (measured) |
| Per-draw overhead in `Model3DDrawPass`: resource lookups, configuration hashing, binding arrays | ~1.0 ms today, about half recoverable (estimate) |
| Skip sun-shadow cascade redraw when the camera, the light and shadow casters are unchanged | −1.3 ms while stationary only |
| Meshlet culling encode when the camera has not moved | −0.9 ms while stationary only |

## 9. Out of scope: GPU cost at full screen

At 3810×1684 the GPU is saturated: about 12.5 ms median stationary. Pipelining does not change that.
Options for a separate design:
- spatial (FSR) or temporal upscaling for builds without DLSS
- cached sun-shadow cascades
- per-light shadow-face caching for the demo's moving light

## 10. Platform impact

| Platform | Impact |
| --- | --- |
| Windows, Linux, macOS (WebGPU/Dawn) | Supported; `webGPUDeviceLock` serializes API calls. |
| macOS and iOS (Metal) | Supported. |
| Headless | Supported; pipelining is off by default in tests. |
| WebAssembly | Setting ignored; stays serial. |
| visionOS immersive | Keeps its own host-driven loop; not covered here. |

## 11. User documentation

This is a user-facing option, so it ships with documentation:
- **Article:** `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/PipelinedRendering.md`, covering:
  - when to enable pipelining and what it costs (one frame of latency)
  - the isolation rules from §5: extract-only main-world reads; no in-place asset mutation while a frame is
    in flight
  - how to measure the effect with `ADAENGINE_STALL_PROBE` and the Sponza frame log
- **Navigation:** linked from the Topics section in `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md`.
- **Example:** the Sponza demo README documents its default and `ADAENGINE_PIPELINED_RENDERING`.
- **Docs check:** DocC build for the `AdaEngine` target.

## 12. Decisions for approval

| ID | Proposal |
| --- | --- |
| D1 | Opt-in per render world; serial stays the default (§4.5). |
| D2 | Accept one extra frame of input latency when enabled (§4.4). |
| D3 | Material snapshot at extraction, rather than locking inside `Material` (§5, R3). |
| D4 | First version enables pipelining only for SceneView render worlds. The UI window stays serial. |
| D5 | The §8 render-path items are separate improvements, measured one by one after this lands. |

## 13. Implementation notes and deviations (pending human review)

Revision 2 (2026-11-09), written during implementation. Items marked **deviation** differ from the text above.

- **Deviation, §4.5 API:** SceneView uses a modifier, `.pipelinedRendering()`, like `frameCaptureLabel(_:)`,
  instead of an initializer parameter.
- **Deviation, §4.3 executors:** a per-world executor for the graph was not enough. The `RenderNode.execute`
  requirement itself was `@RenderGraphActor`, so every node of every graph still ran on one actor. The
  requirement is now nonisolated: a pipelined graph runs on the concurrent executor, a serial graph is still
  started from `RenderGraphActor`, and nodes of one graph still run one after another. Nothing else used
  `RenderGraphActor`.
- **Deviation, R5:** not enforced at runtime. A `@MainActor` system in a pipelined render world hops to the
  main actor, so it cannot race with main-actor state, but it can delay the main loop. SceneView's own
  main-actor `FrameSubmissionSystem` is replaced in pipelined mode by a main-world system that checks
  the main world's cameras; the render-world version would have dropped frame N+1's reservation while frame N
  was still rendering. The UI window's `UIRenderPreparing` stays in its serial render world (D4).
- **R1/R2:** `MainWorld` is removed after `.extract` in pipelined worlds; `Extract` asserts in debug builds
  when read later. The only system that read the main world after extraction, `CreateWindowSurfacesSystem`,
  now reads `PrimaryWindowId` and `WindowFrameRequests` copied at extraction.
- **R3, D3:** `PBRMaterial.stateRevision` changes with every stored property; pipelined extraction replaces
  materials in the extracted sources with `renderSnapshot()` copies, reused until the revision changes.
  Subclasses (`AtmosphereMaterial`) are passed through unchanged. Meshes and textures follow the documented
  replace-not-mutate rule; there is no runtime check.
- **R4:** the render statistics resources already use `Mutex`. `RenderGraphDiagnostics` is unsynchronized
  but is only read through `withExclusiveWorldAccess`, which now waits for the frame in flight.
- **§8, first item:** release builds pass Dawn `skip_validation` (`ADAENGINE_WEBGPU_VALIDATION=0|1` overrides).

### Measurements so far (Sponza, flying light off, 0 local lights, release)

| Scene size | Serial | Pipelined | GPU busy (pipelined) |
| --- | ---: | ---: | ---: |
| 1170×484 | — | 106 FPS | 73% |
| 1890×784 | 95 FPS | 103–108 FPS | 90% |
| 2850×1204 | 94 FPS | 97 FPS | 100% |

The SceneView step on the main thread drops from ~8 ms to ~1 ms, so the overlap works. Two limits remain:
the scene render path takes ~9.5 ms when overlapped (it encodes ~0.7 ms slower while the UI graph runs at
the same time), and the GPU needs ~9 ms per frame at 1890×784. `skip_validation` made no measurable
difference at this point. Criterion 1 (≤ 8.0 ms) is **not met yet**. Lower shadow resolution, coarser
meshlet LOD and disabled meshlets each changed the result by less than 3%.
