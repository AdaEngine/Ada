# Tint development toolchain

`python3 script/ensure_tint.py` builds the revision in `toolchain.json` with the
SPIR-V reader and WGSL writer enabled. It installs the host tool under
`.build-tools/tint/bin/<architecture>-<os>/tint` (`tint.exe` on Windows), outside
SwiftPM's shared `.build`. Initial setup requires Python 3, Git, CMake, Ninja and
a C++ compiler; subsequent runs reuse the verified binary.

The installed manifest records revision, platform and SHA-256. Every invocation
checks the binary hash and runs a real SPIR-V → WGSL conversion. `--check` verifies
an existing cache without building. A conflicting source revision is rejected
rather than resetting a checkout. `ADAENGINE_TINT_CACHE` relocates this tool cache.

The `build-tint` command plugin delegates to the same bootstrap. Runtime host
compiler discovery checks `TINT_EXECUTABLE`, bundled tools, the project tool cache,
then PATH. An invalid explicit override fails instead of silently selecting another
tool. Browser shaders are transpiled during export; no Tint process runs on mobile
or inside WASM.

For rendering or shader changes, run this from the engine root:

```sh
script/validate_webgpu.sh
```

This command bootstraps Tint, compiles a fresh GLSL shader through production
SPIR-V and WGSL compilers, and runs production WebGPU pixel A/B and tile-shadow
checks. Missing Tint or a backend fallback fails the check. It stages the current
focused test sources in a temporary package so unrelated facade/editor targets do
not block rendering validation. It does not claim a full root test run.

Use Swift 6.3.2 with compatible Swan/Dawn. Local Swan development may use
`ADAENGINE_SWAN_PACKAGE_PATH` and `SWAN_LOCAL_DAWN`; use a Swan revision compatible
with the engine's SwiftSyntax constraint. `ADAENGINE_WEBGPU_SCRATCH` selects the
isolated build cache. The current GPU proof used Swan checkout metadata
`1eb45a22c79439b50e9cde774454450e50147149` and Dawn 147.

Browser/mobile runtime checks use the separate
[SpriteInstancingValidation](../../Demos/SpriteInstancingValidation/README.md) app.
