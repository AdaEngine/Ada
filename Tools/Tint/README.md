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

Use Swift 6.3.2. The package pins
[`AdaEngine/swan`](https://github.com/AdaEngine/swan) at
`790df787281e9cf1c2358a11bb42b2ec2df01029` (Dawn 148), JavaScriptKit `0.59.0`,
and SwiftSyntax `603.0.2` for WebGPU builds. AdaEngine and its bundled Gravity
manifest also accept SwiftSyntax 602 for consumers with older macro dependencies.
Swan's checked-in BridgeJS was generated with JavaScriptKit 0.59; update the bridge and JavaScriptKit together, since its
private ABI is not compatible with arbitrary later 0.x versions.

The normal build and WASM export use the remote dependency; no local Swan checkout
is needed. `ADAENGINE_SWAN_PACKAGE_PATH` and `SWAN_LOCAL_DAWN` remain optional
native development overrides. `ADAENGINE_WEBGPU_SCRATCH` selects the isolated
GPU validation build cache. For direct WASM builds set both
`ADAENGINE_WEB_EXPORT=1` and `BUILD_WASM=1`; the `export-web` command plugin sets
both for its nested build automatically.

Browser/mobile runtime checks use the separate
[SpriteInstancingValidation](https://github.com/AdaEngine/AdaExamples/tree/main/Examples/Technical/SpriteInstancingValidation/README.md) app.
