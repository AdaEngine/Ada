# ADR-0030: A Backend-Neutral Acceleration-Structure API in AdaRender

Date: 2026-11-16. Status: accepted for the hardware path tracing feature.
Scope: [approved hardware path tracing design](../Designs/hardware-path-tracing.md).

Relates to [ADR-0021](0021-hybrid-ray-tracing.md), which calls for backend-neutral acceleration-structure
capabilities implemented first by Metal. This ADR defines that API's first concrete shape and implements it first on
SAGA Vulkan for path-tracing intersection; ray dispatch and hybrid reflections stay with ADR-0021.

## Decision

AdaRender exposes GPU ray tracing through backend-neutral types instead of backend-private code:

- `AccelerationStructure` is an opaque resource of kind `.bottomLevel(triangleCapacity:)` or `.topLevel(instanceCapacity:)`,
  created by `RenderDevice.createAccelerationStructure(_:)`, which returns nil on devices that cannot trace rays.
- `RenderDevice.supportsRayQueries` reports whether shaders can query acceleration structures. It is false by default.
- `CommandBuffer.encodeBuild(of:geometry:)` builds a bottom-level structure from triangles
  (`AccelerationStructureGeometry`: vertex buffer, offset, stride of at least 12 bytes, optional 16- or 32-bit indices);
  `CommandBuffer.encodeBuild(of:instances:)` builds a top-level structure from `AccelerationStructureInstance` values
  (structure, transform, mask, instance ID). Both return false where unsupported, like `encodeSpatialUpscale`.
- A pipeline binds a top-level structure through `RenderResourceSet.Binding.Resource.accelerationStructure`.
- Input is validated in AdaRender before a backend sees it (`AccelerationStructureGeometry.validate()`), and an
  instance's transform is converted to the row-major 3-by-4 form the backends take.

Backends implement the API with their own ray-query support. SAGA Vulkan is the first (see the design); Metal and D3D12
can adopt the same API later without changes to callers. Features that use it check `supportsRayQueries` and keep a
software fallback.

## Alternatives

- An internal SPI used only by the path tracer: rejected, because other features (shadows, reflections) need the same
  capability and would otherwise duplicate backend access.
- Exposing SAGA types in the public API: rejected; AdaRender's public surface stays backend-neutral.

## Consequences

- The `RenderDevice` and `CommandBuffer` protocols gain requirements with default implementations, so existing
  conformers keep compiling and report no support.
- Resource lifetime follows the backend's submission retirement; callers keep structures alive until their last use.

## Implementation checklist

- [x] Types, validation and device/command-buffer requirements with defaults in AdaRender.
- [x] SAGA Vulkan implementation and capability reporting (Metal reports no support until it has coverage).
- [x] Core pipelines owner of bottom-level structures and the top-level structure.
- [ ] Other backends (Metal, D3D12): not planned by this ADR.
