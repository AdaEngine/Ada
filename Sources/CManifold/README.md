# Triangle Boolean adapter

The C-only public boundary wraps unmodified Manifold 3.5.1, commit
`cc8a7f66d7d5a560da94346258c5b546af27811e`. Its Apache-2.0 license, authors,
embedded third-party notices, and source hashes are retained in `Vendor`.
Only the 3D kernel is built; optional cross-section, TBB and tracing are disabled.
Swift does not enable C++ interoperability or import upstream C++ types.

Input and output carry position, normal, UV, source identity and face provenance.
The caller owns the cancellation context; cancellation may run concurrently,
but context destruction must follow completion of the operation. Result buffers
remain valid until result destruction. No pointer is retained from an input call.
All C++ exceptions are contained at the C ABI. Closed-manifold input is required;
open terrain needs the separately validated closure/patch policy.

Desktop consumers opt into `MeshTerrainAuthoring`; Ada Studio enables it in its
engine dependency. Default player builds retain data/query APIs without the C++
authoring target. Binary distributions that enable the kernel include `Vendor/LICENSE`,
`Vendor/AUTHORS` and `THIRD_PARTY_NOTICES.txt`; Studio bundles these under `Assets/Legal/Manifold`.
