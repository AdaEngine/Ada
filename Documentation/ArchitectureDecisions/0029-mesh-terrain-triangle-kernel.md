# ADR-0029: A Bounded Triangle Kernel for Mesh Terrain

Date: 2026-11-06. Status: selected for the implementation feasibility path.
Scope: [approved terrain composition design](../Designs/terrain-mesh-composition.md).
Full integrated feature acceptance remains pending.

## Decision

Use unmodified Manifold 3.5.1 (`cc8a7f66d7d5a560da94346258c5b546af27811e`)
behind a narrow C ABI for the supported closed-solid triangle Boolean subproblem.
Keep editable triangle data, regional evaluation, source identity and cancellation
in Ada-owned interfaces. Do not introduce Swift C++ interoperability into clients.
Pin sources and hashes with upstream/embedded third-party license notices.

An explicit single-valued open ground patch can be closed below its surface using
temporary bottom/side faces with reserved provenance. Clip operand contributions
to section domains when needed, evaluate the closed problem, then remove every
temporary closure face from render/query/collision output. This does not claim
general inside semantics for arbitrary open cave sheets; unsupported input is rejected.

Existing sampled-density terrain remains compatible and independently named.
Do not silently voxelize an unsupported triangle operation. Compiled players can
consume products independently of the native authoring kernel.

## Evidence and current limits

Focused native Windows Swift Testing exercises union, a subtracted tunnel,
explicit ground closure/cap removal, UV/source-face transfer, reflected nonuniform
placement, invalid input, budget rejection, empty-then-union evaluation, section
boundary composition and retained modifier movement. Commands and original logs
are retained by task `mesh-terrain-composition`; these are kernel/graph evidence,
not completed UI, platform, performance or full feature acceptance.

Input/decode/output sizes and broad-phase candidate/visit work have explicit limits.
Native cancellation uses one execution context per evaluation. Exceptions never
cross the C boundary. The opaque cancellation context remains alive through the
call; only upstream's synchronized Cancel operation is used concurrently.

Memory estimates for native operation scratch require adversarial profiling;
an input/output budget alone is not proof of exact peak native allocation.
Additional concave/contact/attribute and target-platform fixtures remain required
by the design before the complete feature can be accepted.

## Alternatives

A pure Swift robust triangle kernel would avoid C++ packaging but add significant
intersection/attribute-repair work. CGAL provides broader surface-processing
options with different package/license costs. A density-only extension reuses
current code but does not satisfy the triangle-preserving join contract. None of
these is substituted implicitly if this selected route encounters an unsupported
case; substantive limitations return to the approved design boundary.
