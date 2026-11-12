# AdaEngine developer CLI

`ada_tool.py` is the repository entry point for installing standalone Studio,
building the engine/editor/web player and preparing development dependencies.
It uses Python 3.9+ and its standard library. Run it from a checkout; an absolute
path to `ada_tool.py` also works from another directory. Use `python3` instead of
`python` where appropriate. `--help` is available on every subcommand.

```sh
python ada_tool.py doctor
python ada_tool.py prepare --dry-run
python ada_tool.py prepare
python ada_tool.py install studio
python ada_tool.py install studio --debug --launch
```

## Local SAGA checkout

Keep the SAGA repository beside AdaEngine. Native WebGPU builds and web export
use SAGACompiler for GLSL-generated SPIR-V, including Shader Graph fragments.
Set `ADAENGINE_SAGA_PACKAGE_PATH` to an absolute path if the checkout lives
elsewhere or the AdaEngine source is staged for export. In WSL use the Linux
path to the checkout. Windows release CI checks out SAGA beside AdaEngine;
`ADAENGINE_SAGA_REF` can select a revision that contains the compiler fixes.

```powershell
$env:ADAENGINE_SAGA_PACKAGE_PATH = 'D:/Development/SAGA'
$env:ADAENGINE_VALIDATE_WGSL = '1'
swift test --filter WGSLShaderCompilerTests
```

The test suite translates fresh SPIR-V for both shader stages and verifies the
WGSL entry point and binding reflection. GLSL source remains supported during
the compiler migration.

## Install and run Studio

Both configurations are Standalone distributions, including resources, runtime,
and the source BuildSDK. Installation without `--source` builds the current
checkout; it does not download the latest GitHub release. Debug selects the
debug compiler configuration and has its own installation directory and shortcut.

| Host | Release installation | Debug installation |
| --- | --- | --- |
| Windows x64 | `%LOCALAPPDATA%/Programs/Ada Studio` | `%LOCALAPPDATA%/Programs/Ada Studio Debug` |
| macOS | `~/Applications/Ada Studio.app` | `~/Applications/Ada Studio Debug.app` |
| Linux x64/ARM64 | `$XDG_DATA_HOME/ada-studio` | `$XDG_DATA_HOME/ada-studio-debug` |

On Linux, `XDG_DATA_HOME` defaults to `~/.local/share`. On macOS the CLI builds
the `AdaEditor-Standalone` Xcode scheme, then applies and verifies a local ad-hoc
signature. Xcode must be installed and selected; Command Line Tools alone do not
provide the app build. Linux needs X11/XWayland/WSLg, Vulkan drivers and Zenity.
See [Linux development](Linux.md) for the platform's current limits.

```sh
# Install a complete, already extracted distribution without Swift or a compiler.
python ada_tool.py install studio --source /path/to/AdaStudio-release --destination /path/to/installed-studio
# On macOS, supply the .app and name the exact destination .app.
python ada_tool.py install studio --source "/path/to/Ada Studio.app" --destination "/Applications/Ada Studio.app"
python ada_tool.py run studio
python ada_tool.py run studio --debug
```

Installed launches use bundled SDK/tool discovery instead of saved checkout build
overrides. Overrides explicitly supplied in the caller's environment are preserved.

`--destination` always names the application directory, not its parent.
`--no-shortcut` disables Start menu / desktop entry / Launch Services registration.
Close the installed Studio before updating. Installers validate the full source
and existing destination, reject overlapping paths and links/junctions, stage a
new copy and restore the previous installation if replacement fails. A destination
containing unrelated files is rejected. A failed rollback keeps the backup and
prints its location. `--source` expects a directory; extract ZIP/tar releases first.

## Doctor and preparation

```sh
python ada_tool.py doctor --profile studio
python ada_tool.py doctor --profile wasm --json
python ada_tool.py doctor --profile playground --cloud-panels /path/to/adawebsite/dist-panels
python ada_tool.py prepare studio
python ada_tool.py prepare swift tint
python ada_tool.py prepare wasm
python ada_tool.py prepare playground
python ada_tool.py prepare --skip-system
```

`doctor` does not install or download anything. It checks the selected Swift
version, native build tools, the local SAGA checkout, Lore, WASM
SDK/WSL, frontend tools and Cloud panel inputs according to the profile. JSON goes
to stdout; diagnostic subprocess output goes to stderr. Exit codes: 0 ready,
1 missing requirement or operation failure, 2 usage error, 130 interrupted.
It cannot establish GPU/desktop/runtime correctness by inspecting dependencies.

With no component arguments, `prepare` selects Studio, WASM and playground.
It can download large toolchains. System package managers may
request administrator access. The command uses WinGet/Visual Studio 2022 on
Windows, Homebrew on macOS and apt on Debian/Ubuntu. Install Homebrew and full
Xcode first on macOS. For another Linux distribution, install the packages from
[Linux.md](Linux.md) yourself and pass `--skip-system`.

Windows requires MSVC 14.44+ / Visual Studio 2022 17.14+ for the pinned Dawn
library's STL symbols. `doctor` and builds reject older toolsets before compiling;
`prepare studio` upgrades an existing VS 2022 Build Tools installation when needed.
That machine-wide update uses the standard Windows UAC prompt when the CLI is
running without administrator rights; confirm it manually. Restarts are deferred.
The [Microsoft STL 17.14 implementation](https://github.com/microsoft/STL/blob/vs-2022-17.14/stl/src/vector_algorithms.cpp)
provides the vectorized string-search symbol required by this Dawn binary.

`--skip-system` skips apt/brew/winget prerequisite packages. Swift and other
selected tools are still installed; WinGet is needed if Windows Swift is missing.
If Swiftly reports extra system requirements in this mode, the CLI prints the
post-install script path for manual setup. `prepare playground` only prepares
Node/pnpm and frontend packages; it does not require Visual Studio or Swift.
Cloud panels belong to the separate adawebsite checkout and must be built there.

Versions are pinned in [../Tools/ada-toolchain.json](../Tools/ada-toolchain.json),
following existing project validation: Windows native Swift 6.3.1, macOS/Linux
and WASM Swift 6.3.2. This does not change the Swift 6.2 language mode. Swiftly
installs the selected Unix toolchain without changing the user's global default
or `.swift-version`. The CLI saves its explicit executable path for later commands.
The WASM SDK and Linux Dawn archive are checked against pinned SHA-256 values;
Lore keeps its own version/hash manifest. A compatible existing Node
is reused; otherwise the pinned version is installed in the CLI cache with its
official SHA-256 manifest. pnpm comes from the frontend's
`packageManager` pin. Existing explicit native dependency overrides are retained.

Host configuration, tools and logs live under
`.build-tools/ada-tool/<os>-<arch>/`. Subsequent CLI calls restore that environment;
they do not need an activation command. Explicit process environment overrides
take priority over saved dependency paths. `--swift /path/to/swift` overrides the
saved compiler and adjusts PATH for nested SwiftPM/plugin/packager calls. The
selected compiler must match the host version pin.

Official bootstrap references: [Swift on Windows](https://www.swift.org/install/windows/),
[automating Swiftly](https://docs.swift.org/latest/documentation/swiftlydocs/automated-install/),
[Swift SDK release checksums](https://github.com/swiftlang/swift-org-website/blob/main/_data/builds/swift_releases.yml).

## Build without installing

```sh
python ada_tool.py build engine --debug --jobs 4
python ada_tool.py build studio --jobs 2
python ada_tool.py build studio --debug --scratch-path /path/to/isolated-build
```

`build engine` compiles the AdaEngine target. `build studio` prepares native
dependencies and builds the app; it prints the binary directory or macOS `.app`.
Use `install studio` for a complete runnable distribution on Windows/Linux.
On Windows, a build linked with the DLSS bridge (`script/build_dlss.py`) copies NVIDIA's
`nvngx_dlss.dll`, `nvngx_dlssd.dll` and license next to the executable, and the packager includes them;
see [DLSS](DLSS.md).
Build logs are saved in the host CLI cache. Build stages appear in the terminal
as they run; the last 30 log lines are also printed when compilation finishes.
A failing compiler exits nonzero with the log location. Default builds use their
own scratch directory, leaving the shared SwiftPM `.build` intact. If an explicitly
reused scratch cache belongs to another compiler, choose a new `--scratch-path`.


## Profile Studio with native CPU profilers

`--profile` builds the release configuration with debug symbols, so sampling
profilers show Swift function names while timing stays representative:

```sh
python ada_tool.py install studio --profile --launch
python ada_tool.py run studio --profile
python ada_tool.py build engine --profile
```

The profiling installation lives beside the release and Debug ones (for example
`%LOCALAPPDATA%/Programs/Ada Studio Profile` on Windows) and uses its own
`<target>-profile` build cache, so it never invalidates the release cache.
`--profile` cannot be combined with `--debug`.

- **Windows:** symbols are CodeView PDBs next to the build products; the
  executables reference them by absolute path, so keep the build cache while
  analyzing. Record with Windows Performance Recorder, reproduce the slow action,
  and open the trace in Windows Performance Analyzer (CPU Usage (Sampled),
  grouped by stack):

  ```sh
  wpr -start CPU -filemode
  wpr -stop studio.etl
  ```

  Superluminal and the Visual Studio profiler read the same PDBs.
- **macOS:** the Release app includes a dSYM; use Instruments' Time Profiler.
- **Linux:** DWARF symbols are embedded; use `perf record -g` and `perf report`.

For coarse frame timing without a profiler, set `ADAENGINE_STALL_PROBE=1`
(optionally `ADAENGINE_STALL_THRESHOLD_MS=4`): operations slower than the
threshold print tab-separated `ADA_STALL` lines with their duration.
Besides engine phases (`App.Update.*`, `RenderNode.*`, `WGPU.*`), Studio reports
`Studio.OpenFile`, `Studio.SceneDecode`, `Studio.Highlight` and
`Studio.ProjectTree.Refresh` (columns: start ms, duration ms, phase, bytes, count).

### WebGPU pipeline cache

Native WebGPU (Dawn) builds keep translated and compiled shaders on disk, so a
pipeline variant compiled once is not compiled again on the next launch. The first
launch on a machine, and the first launch after a driver, Dawn or shader change,
still compiles; `WGPU.CreateRenderPipeline.*` stall lines show those compiles.

- Location: `%LOCALAPPDATA%/AdaEngine/PipelineCache/<adapter>` on Windows and the
  user caches directory elsewhere (for example `~/Library/Caches` on macOS), one
  folder per GPU, backend and driver.
- At startup the current folder is trimmed to 512 MB, least recently used entries
  first, and adapter folders unused for 30 days (for example after a driver update)
  are removed. Deleting the cache is always safe.
- `ADAENGINE_PIPELINE_CACHE=0` disables it (for measuring cold compiles);
  `ADAENGINE_PIPELINE_CACHE_DIR=<path>` stores it elsewhere.

### GPU-driven shadows

Static shadow casters are culled on the GPU with WebGPU (see
[shadow casting cost](RenderingFoundation.md#shadow-casting-cost)). For comparisons
and bug reports:

- `ADAENGINE_SHADOW_GPU=0` draws every caster through the CPU-culled path.
- `ADAENGINE_SHADOW_MULTIDRAW=0` keeps GPU culling but replaces multi-draw with one
  indirect draw per mesh.

## Playground and WebAssembly

```sh
# First build Cloud panels in the separate adawebsite checkout: npm run build:panels
python ada_tool.py prepare playground
python ada_tool.py build playground --cloud-panels /path/to/adawebsite/dist-panels
python ada_tool.py serve playground --port 8080

python ada_tool.py prepare wasm
python ada_tool.py build wasm --cloud-panels /path/to/adawebsite/dist-panels --output dist/web
python ada_tool.py serve wasm --port 8080
```

Playground builds the existing `Editor/WebUI` DOM shell. Its frozen pnpm lockfile
is used; this command does not create a separate frontend. `--cloud-panels` (or
`ADA_CLOUD_PANELS_DIST`) selects the existing adawebsite build output. This path
is remembered for subsequent CLI builds.

`build wasm` exports Release DOM Studio and the fixed AdaWebPlayer using the
existing production exporter. `--ui-dist PATH` skips frontend compilation and
uses its existing dist. The default export is `dist/web/{studio,player}`. Repeat
`--studio-origin https://your-host.example` for each allowed editor origin; the
local default is `http://127.0.0.1:8080`. Match the origin to your actual preview
host and port. Production origins must use HTTPS, as enforced by the exporter.

On Windows, enable WSL 2 with an Ubuntu 24.04 distribution first:

```powershell
wsl --install -d Ubuntu-24.04
python ada_tool.py prepare wasm
```

This uses the existing managed Linux cross-build worker and its Swift 6.3.2 SDK.
Native Windows Swift is kept separate. Paths are translated through `wslpath`;
the frontend is built on Windows and reused by the WSL export. On macOS/Linux,
`prepare wasm` installs the checksum-pinned SDK into the selected native Swift.

`serve playground` and `serve wasm` bind only to `127.0.0.1`, support SPA routes
and the `/studio/` asset base, and serve the player from a nested WASM export.
They are static previews: account, publishing, AI and other `/v1/` API operations
return an explicit 503. For a full local Cloud stack, follow
[../Editor/WebUI/README.md](../Editor/WebUI/README.md). No command deploys a site.

## Maintenance and verification

Implementation is split by responsibility in `script/ada_tools/`. The old
platform installers, packagers, bootstrap scripts and rendering validators still
have CI, release-distribution, plugin or CLI callers. They are kept as internal
backends/compatibility entry points; their regression tests remain useful.
Check callers before removing any script as obsolete.

```sh
python script/test_ada_tool.py
git diff --check
```

The suite covers real filesystem installation/upgrade/rollback, invalid inputs,
archive traversal, hash failures, static HTTP routing and a small real SwiftPM
build (when the pinned compiler is installed). Platform-specific installation
and complete Studio/GPU/WASM exports still need verification on their own hosts.

## Browser renderer (SAGA)

Web exports render through SAGA. The export needs a SAGA checkout (`../SAGA`, or `ADAENGINE_SAGA_PACKAGE_PATH`) and
ships its JavaScript WebGPU host as `saga-webgpu.mjs`; it fails with a clear message when the checkout is missing.
Add `?sagadebug` to the page URL to wait for every submission and print SAGA device errors and per-pipeline binding
reports to the console. Web export uses JavaScriptKit's generic BridgeJS runtime and resolves SAGA without Swan or Dawn.

Golden-frame check: pack `Tests/WebGolden/SAGASmoke` into an exported `AdaWebPlayer` and run
`node script/web_golden_saga.mjs <bundle>` (needs `playwright-core` and a WebGPU Chromium; `--record` replaces the
reference). Pass `--actual=<path.png>` to save the captured frame. See [the smoke scene README](../Tests/WebGolden/SAGASmoke/README.md).

## Native SAGA Vulkan development

Set `ADAENGINE_SAGA_NATIVE=1` to build the Windows, Linux, or Android renderer
against SAGA Vulkan. The native build uses the system Vulkan driver. The SwiftPM
build resolves SAGA from the sibling checkout or `ADAENGINE_SAGA_PACKAGE_PATH`.
Set `ADAENGINE_GOLDEN_SAGA=1` and `ADAENGINE_SAGA_WINDOWLESS=1` for the offscreen
3D checks, then run `swift test --filter SagaNative`. Set `ADAENGINE_GOLDEN_OUTPUT`
to an existing directory to collect the rendered PNGs.

For Android APK exports and emulator setup, see [Native Android apps](../Tools/Android/README.md).
