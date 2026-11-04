# AdaScript rig acceptance

The complete recipe ran through the production model generator in its embedded VM.
The prebuilt developer runner also succeeded with swift and swiftc absent from PATH.
The recipe lint has no findings. All 17 selected Swift Testing tests passed.

The resulting GLB retains the original 7,348 vertices and 4,284 triangles.
All 23 joints, normalized weights, inverse binds, original normals and loop seams pass
independent buffer checks. All clip channels agree with the previous native author
to within 4.18e-7 in component values.

Installed Studio imported the actual AdaScript GLB and rendered it on WebGPU/D3D12.
Live snapshots contain three distinct hip poses with advancing frame sequences and no
script errors. Walk images show the intact skull, rib cage, scarf, sword and shield;
the bind pose was captured separately. These are actual native skinning pixels.

The developer harness uses production sources plus a standalone resource-scope adapter.
The Windows macro plugin emits a nonfatal DecodingError diagnostic during a successful
build; the build log is retained. Full root/Editor builds were not performed here.
Installed Studio predates the bridge extension, so it validates output playback only.
A rebuilt app bundle and physical iPad execution remain unverified. No automatic anatomy
inference, imported-mesh weight editor, full intersection audit or performance benchmark
is claimed.
