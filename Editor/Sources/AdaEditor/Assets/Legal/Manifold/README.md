# Manifold notices

Ada Studio enables the optional `MeshTerrainAuthoring` package trait on desktop.
The triangle kernel is Manifold 3.5.1, unmodified selected 3D sources from
https://github.com/elalish/manifold at cc8a7f66d7d5a560da94346258c5b546af27811e.

`LICENSE`, `AUTHORS` and `THIRD_PARTY_NOTICES.txt` preserve upstream and embedded
notices. `UPSTREAM.json` records the source revision and original file hashes.
The wrapper and its build selection live in `Sources/CManifold` in AdaEngine.
Default compiled-player consumers do not enable this authoring dependency.
