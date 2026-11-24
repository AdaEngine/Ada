# Ada Studio CSG Shapes and UVs

The full scope in [the approved CSG design](../Designs/studio-csg.md) adds sphere and cylinder operands and automatic UVs. Continue in `codex/studio-csg`.

1. Keep the serialized operand marker and add an optional shape field. Missing shape means box. Evaluate closed sphere and cylinder surfaces through the existing Boolean path.
2. Generate UVs for the winning source faces, including reversed cutter faces. Use planar charts for box faces and cylinder caps, angular charts for curved surfaces, and a repeat control for the group. Carry the same UVs and base-color image through editor preview, Play, and portable GLB.
3. Extend the existing Inspector using the [visual proposal](../Examples/studio-csg-shapes-uv.html). Pick a shape before adding it to the ordered group. Inspect UVs with the checker or an image from project assets. Keep the standard transform gizmos and record changes through scene history.
4. Extend the user guide and repository skill. Bundle a Studio agent skill with a doorway example that uses revisioned scene edits. Verify skill discovery and application of its authoring operations, mixed operations, scene round-trip, UV seams, inspection after Stop, and the GLB and collider loaded from native scene data. Keep visual evidence and packaged player checks separate.
