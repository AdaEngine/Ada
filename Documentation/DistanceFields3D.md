# Static world distance fields

`Environment3D.distanceField` adds bounded, world-space signed-distance-field
visibility to the primary directional light. It is optional and defaults to
nil. Existing directional shadow maps continue to supply visibility from moving
objects and geometry beyond the field or configured trace range. Receivers and
the directional source retain their existing receive/cast-shadow flags. Missing
or unloaded fields leave the ordinary shadow path unchanged.

```swift
let field = try AssetsManager.loadSync(DistanceField3D.self, at: "Field.sdf3d")
environment.distanceField = .init(asset: field, maxDistance: 12, maxSteps: 48,
    surfaceBias: 0.12, softness: 0.02)
environment.distanceField?.debug = true // green: visible, red: SDF-occluded
environment.distanceField = nil        // ordinary lighting
```

This is a static bounded composite. It does not maintain camera-centered
clipmaps, stream a global world, update skeletal deformation or implement
ray-traced GI. The lighting result is a shadow supplement, not Lumen. A baked
occluder stays in the field until it is rebaked: changing that mesh's transform,
visibility, cast-shadow participation or topology requires updating the asset.
Runtime light direction and receiver position may change without rebuilding it.

## Asset layout

`.sdf3d` is JSON with version `1`, encoding
`signed-distance-r32f-slices-v1`, `minimum` as an xyz object, scalar `voxelSize`,
three integer `counts`, a basename-only `data` path and optional integer
`atlasColumns` (default `1`). Distances are in world metres; negative is inside
an occluder. A sample's position is `minimum + (x,y,z) * voxelSize`.

The raw file is a little-endian R32F two-dimensional atlas. With columns `c`,
its width is `nx*c` and height is `ny*ceil(nz/c)`. Node `(x,y,z)` is at pixel
`(x + (z % c)*nx, y + (z / c)*ny)`. Padding for unused tiles is present in the
raw byte count. Shader interpolation manually fetches the eight grid corners;
it never samples across slice borders or atlas padding.

The loader validates positive finite voxel size, finite placement/extents, node
counts, columns, exact atlas dimensions and byte count, finite signed samples,
and a local file path without traversal or symlink escape. Dimensions are at
most 4096×4096 and the padded atlas has a strict 32 MiB ceiling. Validation and
upload occur during loading, with no per-frame field reconstruction.

## GPU tracing

The shared production include `AdaEngine/DistanceField3D.glsl` is used by PBR
and the GPU regression fixture. It exposes raw trilinear sampling and directional
visibility. Rays are clipped to the known field bounds. An interpolation margin
of half the voxel diagonal is deducted before advancement/hit tests, preserving
thin or diagonal blockers at the cost of conservative shadow expansion. The
surface origin uses the geometric normal, with a minimum normal bias slightly
larger than that margin. This avoids material normal-map ripples moving shadow
origins into the sampled surface. A cone estimate provides optional softening.

Trace distance is sanitized to 0.1–100 m and the step budget to 1–128. A trace
that exhausts its steps within the field returns occluded, rather than silently
reporting an untested path as clear. Grazing rays and a small step budget may
therefore darken too much. Voxel size, bias, trace budget and softness are quality
controls; a coarse field does not resolve arbitrary thin geometry exactly.

Only the primary directional direct-light term is attenuated. Ambient lighting,
emission, local lights, GI probes, SSR and volumetric fog retain their existing
algorithms. The optional debug mode colors mesh receivers by SDF sun visibility;
it is not a visualization of a complete ray-traced scene. Hardware ray tracing
is not required by this path.

No new full-screen pass or per-pixel CPU ray query is added. The main pass binds
the loaded R32F atlas and one cached 48-byte uniform. Existing disabled scenes
take the shader's off branch. Actual performance still depends on coverage,
ray length, step count and field detail; native evidence must establish a useful
budget on each target machine.
