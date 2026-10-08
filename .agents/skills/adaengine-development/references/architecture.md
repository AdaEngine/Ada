# AdaEngine Architecture

Read this reference when locating ownership, introducing a dependency, or changing behavior across modules.

## Package Shape

AdaEngine is a SwiftPM workspace with a modular engine package at the repository root and a separate editor package in `Editor/`.

The root `AdaEngine` product is the high-level facade. Prefer implementing behavior in the narrow owning target and re-exporting it only when the public facade requires it.

### Foundation and runtime

- `Math`: vectors, matrices, quaternions, geometry, and numeric primitives. Keep it independent of engine layers.
- `AdaUtils`: collections, events, filesystem, reflection, IDs, weak storage, coding helpers, and reusable infrastructure.
- `AdaEngineMacros`: Swift macros used by components, bundles, and systems. Macro changes require checking both generated API shape and downstream compile behavior.
- `AdaECS`: entities, components, archetypes/chunks, queries, resources, commands, events, systems, schedulers, and world storage.
- `AdaApp`: app lifecycle, worlds, plugins, app scenes, frame pacing, and main scheduler setup.
- `AdaPlatform`: application/window/platform integration for Apple, Linux, Windows, and browser environments.

### Engine features

- `AdaAssets`: asset loading, serialization, GLTF/OBJ support, and resource integration.
- `AdaRender`: GPU abstractions, materials, meshes, textures, shaders, cameras, render items, render graph, and backend selection.
- `AdaCorePipelines`: built-in render pipelines and shader resources.
- `AdaTransform`: transform components and hierarchy behavior.
- `AdaInput`: input state and events.
- `AdaAnimation`: reusable animation systems and data.
- `AdaAudio`: audio components and miniaudio-backed engines.
- `AdaText` and `AdaTextShaper`: font/text layout, shaping, atlas integration, and text rendering.
- `AdaUI`: declarative UI DSL, view-node tree, layout/render integration, controls, gestures, plugins, and native representables.
- `AdaPhysics`: 2D/3D physics integration through box2d and box3d.
- `AdaSprite` and `AdaTilemap`: 2D rendering, lighting, sprite assets, and tilemaps.
- `AdaScene`: high-level 2D/3D scenes, serialization, editor hooks, hot reload, scriptable components, and keyframe animation.
- `AdaEngineEmbeddable`: host-platform embedding and preview integration.
- `AdaWeb`: browser-specific app, asset, platform, rendering, and UI support.

### Tools and applications

- `Editor/`: its own SwiftPM package with executable `AdaEditor`, tests, resources, package tooling, local root-AdaEngine dependency, and `project.yml` for a macOS app wrapper generated with XcodeGen.
- `Demos/`: real examples and stress/benchmark scenes. Use these to understand current API style and for manual/runtime validation, but do not treat a demo as the implementation layer.
- `Plugins/`: SwiftPM build/command plugins for WebGPU/Tint, web export, shader transpilation, and texture atlas generation.
- `Tests/<Module>Tests`: focused tests aligned with root modules. `Editor/Tests/AdaEditorTests` belongs to the separate editor package.

## Dependency Direction

Keep low-level targets independent of high-level ones. In particular:

- `Math` and `AdaUtils` must not depend on app, scene, UI, or renderer layers.
- ECS algorithms belong in `AdaECS`, not in `AdaScene` or `AdaEngine`.
- App/plugin lifecycle belongs in `AdaApp`; platform windowing belongs in `AdaPlatform`.
- Renderer-neutral data should not acquire a platform dependency without need.
- AdaUI may integrate with rendering/input/app layers, but feature-specific game or editor behavior should remain outside AdaUI.
- Editor-only state, tooling, and UX stay in `Editor/` unless the engine needs a reusable runtime/editor-reflection primitive.

Before adding a target dependency, inspect the relevant dependency arrays in `Package.swift`. Circular ownership usually means the abstraction is in the wrong module.

## Public Extension Points

- `Plugin` configures an `AppWorlds` lifecycle and is `@MainActor` at setup/finish/destroy boundaries.
- `Component`, `Bundle`, `PlainSystem`, and `System` macros provide the preferred ECS declarations.
- `World`, `Scheduler`, `SystemParameter`, query targets, resources, commands, and events are the core runtime extension points.
- `App`, `AppScene`, and scene modifiers define application composition.
- AdaUI's `View`, `ViewModifier`, builders, view nodes, environment values, and representables define UI extension points.
- Render graph nodes/resources and asset types are the renderer/asset extension points.

Follow an existing neighboring implementation before inventing a parallel abstraction.
