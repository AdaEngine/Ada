# Native AdaScript (experimental)

Compile supported AdaScript into native code with Gravity, then install metadata
and callbacks through `AdaScriptNativePlugin`. Gravity owns C11 generation, the
C ABI and native memory. AdaEngine owns world capabilities and the ECS adapters.
Native execution does not use Gravity bytecode or fall back to the VM.

## Development dependency

The pinned Gravity revision includes `GravityAOT` for ordinary engine and Editor
builds. To develop the compiler or run export tests against a local checkout:

```sh
export ADAENGINE_GRAVITY_PACKAGE_PATH=/Users/vlad-prusakov/Developer/gravity-lang-aot
```

The Editor package explicitly depends on `GravityAOT` and `CGravity`. A packaged
Editor also needs access to the engine checkout, Python, make, Clang and Swift.

## Automatic Editor export

For an AdaScript project, choose **Build → Export AdaScript to macOS…** or
**Build → Export AdaScript to Web…**. Documents are saved before exporting.

The exporter loads project and locked library sources, performs type checking,
prepares native host conveniences and calls Gravity's `tools/aot_build.py`.
It creates the native archive, C accessor target, game executable package,
resource bundle and detached scene payloads. It checks the generated module's
metadata, component/resource bindings and startup-system configuration before building the player. macOS
exports include an `.app`; Web exports invoke the existing `export-web` plugin
for the engine/game WASM, JavaScript loader and resource manifests.

Outputs go to `Exports/macOS` or `Exports/Web`. Compilation and packaging happen
in an unpublished directory. Failed exports preserve previous output. An
existing directory is replaced only if it has the native-export marker. The
archive and generated SwiftPM package remain available alongside the player.
Rebuild that package with `ADAENGINE_GRAVITY_PACKAGE_PATH` set to the same checkout.
The `.a` in the package is a host-platform archive; Web builds compile its C
source for the WASI target rather than linking the host archive.

Web uses Swift 6.3.2 and `swift-6.3.2-RELEASE_wasm` by default. The generated package pins JavaScriptKit 0.53 for the engine's current Swan binding. Override with
`ADA_WEB_SWIFT_EXECUTABLE` and `ADA_WEB_SWIFT_SDK`. Exporting does not publish a
website, sign an app, create an XCFramework or deploy to an iOS device.

## Runtime capabilities

- `@component` and `@replicated_component` structs register world-local native
  schemas. Queries reuse the existing dynamic cursor and resolve with/without
  filters; component writes update normal ECS change ticks.
- `@resource` declarations use `AdaScriptNativeResources`. `autoInsert: true`
  supplies missing defaults. Registered Swift resources use reflected access;
  `@resource(Input)` supplies the existing input-action snapshot.
- `@system` installs native callbacks in the declared scheduler. Before/after
  dependencies and an explicit startup system are validated. Structural commands
  declare deferred world access; source-defined resources use one conservative
  write-access carrier.
- `context.world` supports spawn, insert, remove, despawn, changeScene and
  reloadScene. Structural mutations use `Commands`, and scene-spawned entities
  are tracked by `SceneNavigator` for replacement/reload.
- Native component constructors use registered engine constructor descriptors.
  Editor preparation resolves named arguments and defaults to those descriptors.
- `Assets.load`, typed loads/preloads and saves use AdaAssets handles and its
  scoped cache. Web player assets preload asynchronously during plugin setup;
  callbacks can then resolve cached references synchronously. Uncached Web loads
  and Web filesystem saves report errors. `Assets.loadAsync` and typed async loads
  run through the same cache without blocking callbacks. Native async saves use
  AdaAssets on supported filesystems and report a detached failure result on Web.
- Typed commands and replicated schemas register in the existing multiplayer
  registry. Native systems send through its outgoing queue, bind received
  commands, and dispatch RPC handlers with the authenticated source. Editor
  preparation retains declarations while adapting RPC parameter metadata.
  Networking requires source schema metadata through the plugin's `sources`
  initializer argument and `MultiplayerPlugin` installed first.
- `async`/`await` execute compiled coroutines. `Tasks.start`, `Tasks.promise`,
  `Tasks.nextFrame`, `Time.sleep` (game time) and `Time.sleepRealTime` work in
  native systems and scriptable objects. Locals, expression temporaries and loop
  cursors survive suspension. Each owner resumes inside its declared scheduler
  or lifecycle access. Removing an owner, replacing a scene or stopping the plugin
  cancels pending tasks and operations; task count, resume count and execution fuel
  are bounded.
- `@scriptable` supplies native ready/update/fixedUpdate/event/destroy callbacks,
  required components, exported state and the existing Codable registry envelope.

Exported scenes preserve hierarchy and prefabs, persist camera settings while rebuilding transient camera render components, and resolve tile map handles after asynchronous asset preloading. Transform position/scale animations are serialized
as versioned `KeyframeClip` JSON, including interpolation curves and once/loop/
ping-pong modes, and restored as `KeyframeAnimator` components. Nested prefabs
preserve their clips.

The exported player installs the project's input actions, feature plugins,
physics configuration and scene entry. macOS multiplayer uses LocalTCPTransport;
Web accepts the existing browser-lobby session and CloudWebSocketTransport, or
runs solo with InMemoryTransport when no lobby session is supplied.

Host capabilities expire after the synchronous callback. World/resource/input
handles and component drafts cannot be used after suspension. A receiver can
read freshly rebound declared resources; aliases to earlier callback capabilities
fail with a stale-handle error. Explicit `@nonsendable` values are rejected at
suspension, including values nested in objects/lists. Timer/asset operation results
are detached and may survive suspension. The Gravity
facade serializes native storage and host callbacks with a per-module lock and
keeps code owners alive for all metadata reads. Its default allocation limit is
64 MiB. Detached Swift operation handles are traced from live native owners and
task frames so per-frame timers remain bounded; C arena garbage collection and
native hot reload are not implemented.

## Limits and validation

This remains an experimental compiler subset. Unsupported Gravity constructs,
AdaScript views/tools remain unavailable and fail explicitly.
No unsupported construct silently switches to interpreted execution.

`Movement.ada` validates native ECS/lifecycle integration.
`HostAdapters.ada` goes through the native source preparation step and validates
world commands, Input, constructor capabilities and multiplayer round trips.
`Async.ada` validates coroutine state, native promises, clocks, cancellation,
borrowed capability expiry and scriptable lifecycle. Gravity executes the same
async C host proof under sanitizers and in freestanding WASM with no VM imports.

```sh
ADAENGINE_DISABLE_SWAN=1 swift test --filter AdaScriptNative
```

Editor export tests run a real multi-source AOT compiler, link and execute its
archive from a C host, detach scene payloads, parse the generated player and
check that failure preserves the old export. Separate app/browser validation is
needed for rendering and deployment evidence. Browser AudioPlugin uses a
miniaudio mixer with its device disabled and sends copied Float32 PCM to Web Audio.
The export bundles `engine-audio.js` for every product. Output waits for a trusted
pointer/key gesture to resume AudioContext; mixing does not advance while output
is suspended. WAV data and playback copies use independent owned decoders.
Cloud relay Host/Peer acceptance remains separate validation work.
