# Meshlet preparation v1

Run the CPU-only preparation tool before loading the model:

```text
python script/prepare_meshlets.py path/to/model.gltf
python script/prepare_meshlets.py path/to/model.glb --maximum-triangles 126
```

The tool emits `model.gltf.meshlets` and a JSON receipt beside the source. Keep the
sidecar beside its model when packaging assets; no absolute cache path is encoded.
The receipt records SHA-256 hashes of the source file, external geometry buffers
and sidecar, builder identity, triangle count and meshlet count per primitive.
Profiles 64/64, 64/96 (default), and 64/126 are available for comparison.

The default builder is **AdaEngine's deterministic reference scan**, not
meshoptimizer. A separate native adapter is available:

```text
python script/build_meshlet_tool.py
python script/prepare_meshlets.py path/to/model.gltf --builder native
```

The native tool pins meshoptimizer **1.3**, commit
`9e1f07b159d3cb777f1c67ed31fc11fd117986f4`, and verifies SHA-256 of its header,
clusterizer, allocator, simplifier, index generator and MIT license before compilation. Sources and binaries
live only in `.build-tools/meshlet-builder`; the adapter has no root SwiftPM,
runtime or WASM dependency. [Upstream source](https://github.com/zeux/meshoptimizer/tree/9e1f07b159d3cb777f1c67ed31fc11fd117986f4)
and [MIT license](meshoptimizer-LICENSE.md). The standalone native build was
verified with clang++ on Windows; macOS/Linux compilation remains unverified.

The C++ adapter calls `meshopt_buildMeshletsScan`, then reconstructs every local
triangle and rejects any change to source index order, winding or multiplicity.
Python independently checks contiguous coverage, bounds and profile limits.
The receipt records the native tool/source hashes and whether cluster boundaries
match the reference scan. Repeated-vertex triangles may make native scan close a
cluster earlier; differing boundaries are allowed while exact source coverage is
mandatory. An adapter failure aborts preparation without writing a partial
sidecar; the existing source geometry remains usable. Use the explicit reference
builder when investigating a native-tool incompatibility.

Clusters preserve the original normalized triangle sequence, winding, duplicate
triangles and degenerates. Each cluster has at most 64 distinct source vertex
indices and the selected maximum triangle count. UV seams remain distinct vertex
indices. No geometry, texture or material is simplified or removed. Triangle fans
use the same fan-to-list conversion as `GLTFImportResult.Primitive.convertTopology`;
strips/lines/points retain the original renderer path. Unsupported sparse accessors
are rejected by the tool rather than silently normalized differently.

`MeshletGeometry.scan` provides the same explicit CPU algorithm for tools and
procedural fixtures. Assign its result to `MeshDescriptor.meshlets` before
`Mesh.generate`; procedural generation without prepared data stays unchanged.
The part initializer checks prepared data against its source descriptor. No
preparation occurs at first draw or inside rendering.

## Binary contract

All scalar values are explicitly little endian. Bounds are float32; counts and
offsets are uint32. The file never contains Swift struct memory or GPU handles.

| Section | Layout |
| --- | --- |
| Header, 24 bytes | ASCII `ADAMSHL1`, schema uint32 `1`, max vertices uint32, max triangles uint32, part count uint32 |
| Part, 28 bytes | mesh index uint32, primitive index uint32, vertex count uint32, index count uint32, cluster count uint32, source digest uint64 |
| Cluster, 32 bytes | first index uint32, index count uint32, AABB min xyz float32, AABB max xyz float32 |

Each part header is followed by its cluster records. Source indices are not
duplicated on disk: all clusters cover contiguous ranges of the unchanged source
index array. Runtime geometry holds a copy-on-write reference to that normalized
array, preserving the original index/vertex buffers for fallback and other passes.

The source digest is FNV-1a 64 over uint32 vertex/index counts, float32 xyz positions
in source vertex order, then uint32 normalized indices. It is a cache fingerprint,
not a security hash; SHA-256 provenance is recorded separately in the receipt.
Runtime additionally checks exact coverage, unique vertex limits and conservative
bounds against the actual source positions before attaching prepared data.

The decoder bounds input to 64 MiB and 65,536 primitive records, checks available
bytes before allocations, rejects duplicate keys, nonfinite or inverted bounds,
gaps, overlaps, unsupported versions, malformed ranges and trailing data. Missing,
stale or corrupt sidecars retain original geometry with an import warning when
data was present but could not be used. Static opaque eligibility remains a
renderer decision; meshlet data does not make skinned or transparent draws eligible.

The v1 importer discovers local/packaged filesystem sidecars through the same
relative model URL. Browser delivery/runtime acceptance is unverified and remains
the ADR P6 gate; an unavailable sidecar safely leaves legacy geometry active.

## Native preparation evidence, 2026-11-03

The pinned Windows adapter prepared full Sponza (59,099 clusters / 405 primitives)
and Ivy (63,746 / 2), plus both PT lighting LOD files. Every native cluster boundary
matched the reference scan for these assets, in addition to exact triangle
sequence reconstruction. Original `.gltf` and `.bin` geometry was not changed.

The combined PT LOD contains 121,242 unique source triangles; scene node instances
raise the rendered count. A profile comparison on that same unique geometry gave:

| Profile | Clusters | Mean vertex utilization | Mean triangle utilization | Duplicated vertex references | Sidecar bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64/64 | 2,049 | 82.45% | 92.46% | 12,562 | 66,736 |
| 64/96 | 1,684 | 97.67% | 75.00% | 9,709 | 55,056 |
| 64/126 | 1,667 | 98.43% | 57.72% | 9,452 | 54,512 |

Preparation took approximately 0.89 seconds per profile in this single run,
including Python loading, native execution, reference comparison, bounds and
digest validation. This is not an isolated native-builder timing or a renderer
performance benchmark. The default remains 64/96 pending renderer A/B results.
Receipts and the exact comparison are in
[Preparation-2026-11-03](../../Evidence/Meshlets/Preparation-2026-11-03).

## Additive adaptive LOD hierarchy

The exact v1 partition above remains unchanged. To add actual geometric coarsening:

```text
python script/build_meshlet_tool.py
python script/prepare_meshlets.py path/to/model.gltf --builder native
python script/prepare_meshlet_lod.py path/to/model.gltf
python -m unittest script/test_prepare_meshlet_lod.py
```

`MeshletLOD.exe` starts with exact leaves of up to four scan clusters. It attempts
to merge groups of two to four adjacent nodes into a parent, using
`meshopt_simplify` with a 50% target, `meshopt_SimplifyLockBorder` and
`meshopt_SimplifyErrorAbsolute`. Inputs are compacted by **source vertex ID**, never
by position; output indices reference those same original vertices and attributes.
An additional exact boundary-edge comparison rejects a parent if simplification
changed its source-ID boundary. This preserves boundaries when neighboring groups
select different hierarchy levels. No runtime simplification or vertex movement
occurs.

Only parents with fewer triangles than their combined children are retained.
Unreducible groups become forest roots; disconnected leaf cards can therefore
remain exact at every distance. They are not silently pruned or recolored as
pretend LOD. Source material groups stay separate, and nonopaque/deformed/unsupported
preparation is explicitly skipped. The JSON receipt reports source/coarsest triangle
counts, reductions, tree depth, flat cluster/index counts and skipped primitives.

Error stores cumulative absolute simplifier error plus a conservative visual
heuristic floor of `0.001 × original group diagonal` for reduced nodes. The floor
avoids unconditional zero-error planar coarsening. It is **not a proven UV-error
bound**. Node bounds enclose the original subtree; parent bounds/errors are
monotone. A valid render cut chooses a parent or its descendants, never both.

The separate `<model>.meshletlod` file uses `ADAMLOD1`, schema 1, and the same
24-byte profile header as v1. Each part has a 40-byte header (mesh/primitive IDs,
vertex/source-index/flat-index/cluster/node/root counts and base source digest),
followed by 32-byte clusters, 60-byte hierarchy nodes, UInt32 root IDs and the
shared UInt32 index stream containing every node's approximation. Nodes store
parent sentinel/child range/cluster range/original source span/level and local
min/max/error. Fields are explicit little-endian scalars. Decoder input is bounded
to 512 MiB; checked conversions/ranges precede allocations.

The loader validates source identity, exact leaf coverage, parent/child ownership,
acyclic bottom-up order, strict parent triangle reduction, conservative nested
bounds, error monotonicity, vertex membership and complete forest coverage.
Missing/stale/corrupt hierarchy data preserves the exact v1/base renderer. GPU
buffer and candidate limits still apply independently; a larger decoder budget
does not imply that every hierarchy fits the current backend's 128 MiB buffer cap.

The native 32×32 grid test reduces 2,048 source triangles to a 602-triangle coarsest
forest, verifies exact group boundaries and checks complete nonoverlapping source
coverage for every tested cut. This establishes actual simplification, not a
renderer performance claim. Existing strongly simplified PT LOD assets and
disconnected ivy may have little or no further reduction; use original geometry
for evaluating hierarchy usefulness.
