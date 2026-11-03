# AdaEngine Architecture Decision Records

This directory records accepted architectural decisions for AdaEngine. An ADR
describes the intended design even when its implementation is still planned.

## Status values

- **Proposed**: under discussion and not yet binding.
- **Accepted**: the design is the source of truth for implementation work.
- **Superseded**: replaced by a newer ADR.
- **Rejected**: considered but deliberately not selected.

## Implementation values

- **Planned**: no production slice of the decision has shipped.
- **Partial (foundation shipped)**: a tested production slice has shipped, but
  the ADR's own implementation checklist still has open requirements.
- **Partial (worktree foundation; not released)**: a tested implementation is
  available in an isolated worktree, with remaining ADR requirements open.
- **Partial (local foundation; not released)**: validated implementation in the
  current checkout, with remaining platform or feature requirements open.
- **Implemented**: every normative requirement in the ADR is shipped and its
  validation is recorded.

## Ada Script decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0001](0001-ada-script-annotation-modules.md) | Accepted | Implemented | Annotation-driven modules, imports, and discovery without `main()` |
| [ADR-0002](0002-ada-script-ecs-query-api.md) | Accepted | Implemented | Iterator-based ECS queries, canonical filter syntax, and inferred access |
| [ADR-0003](0003-ada-script-components-and-resources.md) | Accepted | Implemented | Ada Script-defined components and resources backed by generated Swift types |
| [ADR-0004](0004-ada-script-world-capabilities.md) | Accepted | Partial (all but asset/UI capabilities shipped) | Capability-scoped world access and deferred structural changes |
| [ADR-0005](0005-scriptable-objects-and-coding.md) | Accepted | Implemented | Scriptable object lifecycle, registration, and scene coding |
| [ADR-0006](0006-ada-script-adaui-integration.md) | Superseded | Partial (foundation shipped) | Previous AdaScript and AdaUI integration design |
| [ADR-0007](0007-ada-script-runtime-and-hot-reload.md) | Accepted | In progress (portable AdaEditor macOS game window supports source-compatible reload) | Transactional module generations, safe-point hot reload, and runtime failure isolation |
| [ADR-0008](0008-adascript-projects-on-ipados.md) | Accepted | Partial (project foundation shipped) | Portable AdaScript projects, iPadOS runtime sessions, Files/iCloud, and Git ownership |
| [ADR-0009](0009-adascript-runtime-configuration.md) | Accepted | Partial (all but device validation shipped) | Declarative entry plans, plugin presets, typed settings, and runtime-window configuration |
| [ADR-0010](0010-adascript-native-adaui-extension-registry.md) | Accepted | Planned | Versioned descriptors and host factories for native AdaUI views and modifiers used by AdaScript |
| [ADR-0015](0015-adascript-async-tasks-and-coroutines.md) | Accepted | Partial (worktree foundation; not released) | Structured AdaScript async functions, awaitables, task ownership, timers, background I/O, and safe coroutine resumption |
| [ADR-0016](0016-temporarily-disable-adascript-adaui.md) | Accepted | Partial (disablement shipped; redesign planned) | Temporarily disable AdaUI views in AdaScript and define the compiler/catalog/runtime redesign |
| [ADR-0023](0023-studio-tools-ui-panels.md) | Accepted | Partial (local foundation; not released) | Project-local Studio tools with .ui panels, detached bindings/actions and document history |
| [ADR-0024](0024-ada-script-testing.md) | Proposed | Partial (all but timeout and Editor integration; not released) | `@test` functions inline or under `Tests/`, an isolated `TestWorld` per test, and a runner bridged into `swift test` |

## Multiplayer decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0011](0011-multiplayer-runtime-boundaries.md) | Accepted | Partial (foundation shipped) | Optional transport-independent multiplayer runtime and plugin extension model |
| [ADR-0012](0012-host-authoritative-replication-and-rpc.md) | Accepted | Partial (foundation shipped) | Host-authoritative marker replication, interpolation, and typed RPC |
| [ADR-0013](0013-multiplayer-transports-and-cloud-relay.md) | Accepted | Partial (foundation shipped) | Apple LAN transport and region-gated AdaEngine Cloud WebSocket relay |
| [ADR-0014](0014-declarative-multiplayer-schemas.md) | Accepted | Partial (Swift and portable AdaScript component/command paths shipped) | Generated Swift and AdaScript schemas for typed RPC and declarative ECS replication |

## 3D rendering decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0017](0017-temporal-antialiasing-and-metalfx.md) | Accepted | Partial (local foundation; not released) | Temporal antialiasing and MetalFX |
| [ADR-0018](0018-local-lights-and-shadow-scheduling.md) | Accepted | Implemented (Metal and native WebGPU; Apple mobile unverified) | Local lights and shadow scheduling |
| [ADR-0019](0019-environment-lighting-and-postprocessing.md) | Accepted | Partial (exposure and bloom local foundation; not released) | Environment lighting and postprocessing |
| [ADR-0020](0020-gpu-visibility-and-animation-lod.md) | Accepted | Implemented on Metal and WebGPU with CPU fallback | GPU visibility and animation LOD |
| [ADR-0021](0021-hybrid-ray-tracing.md) | Accepted | Planned | Hybrid ray tracing |
| [ADR-0027](0027-3d-rendering-pipeline-gap-roadmap.md) | Accepted | Partial (Stages 0 and 1 first slices; not released) | 3D pipeline gap analysis and staged roadmap: post stack, materials/glTF extensions, morph targets, transparency, atmosphere, lighting scale, content features, diagnostics |
| [ADR-0028](0028-meshlets-and-portable-cluster-culling.md) | Proposed | Planned | Offline meshlet assets, CPU reference and portable Metal/WebGPU cluster culling with indexed compaction; native mesh shaders deferred |

## 2D rendering decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0022](0022-2d-rendering-feature-roadmap.md) | Accepted | Partial (local foundation; not released) | Sprite layout, tile orientation, picking, chunk rendering, instancing and 2D effects informed by Bevy |

## Voxel graphics decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0025](0025-voxel-graphics-and-magicavoxel-import.md) | Accepted | Partial (import, animation, dynamic world and physics; editor integration shipped; not released) | CPU-meshed voxels, layered MagicaVoxel import with hybrid hierarchy/merged scene, animation, chunked dynamic world and physics |

## Studio agent decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0026](0026-scripted-asset-generation-and-autonomous-studio.md) | Accepted | Implemented (not released) | Sandboxed AdaScript generators for voxel models, GLB models, WAV sounds and PNG sprites, measured audio, the `AudioSource` component, and an autonomous design-plan-build-accept workflow for Studio agents |
