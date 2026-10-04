# Ada Studio CLI

The standalone macOS application includes `Contents/MacOS/adastudio`. This is a
second entry into the same executable: it dispatches before `AppRuntime` starts
and uses the editor's project validator, AdaScript builder and native exporter.
No window, recent-project update or agent connection is required. The iOS entry
point, embedded runtime and mobile agent tools retain their existing behavior;
CLI implementation and SDK staging are macOS-only.

```bash
STUDIO="/Applications/Ada Studio.app/Contents/MacOS/adastudio"
"$STUDIO" --help
"$STUDIO" --version --format json
"$STUDIO" doctor --format json
"$STUDIO" project inspect --project ./MyGame --format json
"$STUDIO" validate --project ./MyGame --format json
"$STUDIO" build --project ./MyGame --target macos --configuration release \
  --output ./Build/MyGame --format json
"$STUDIO" export --project ./MyGame --target web --swift /path/to/swift \
  --swift-sdk swift-6.3.2-RELEASE_wasm --output ./Build/Web --format json
```

Source development uses `swift run --package-path Editor AdaEditor
--ada-studio-cli <command>`. `ADAENGINE_GRAVITY_PACKAGE_PATH` selects the local
AdaScript compiler checkout. Installed Studio resolves its SDK from its own
bundle and never falls back to the developer's checkout. `--sdk` or
`ADA_STUDIO_SDK` explicitly selects another SDK.

## Commands and scope

- `project inspect`: decode, migrate in memory and validate metadata/layout;
  return the resolved project without rewriting metadata.
- `validate`: read saved AdaScript, enforce the project's type-checking mode,
  check the entry scene and validate runtime bindings through the existing
  builder. This does not import every asset, execute gameplay or compile Swift.
  SwiftPM projects receive metadata/layout validation only; the JSON report
  states `validationScope` explicitly.
- `doctor`: locate the build SDK, Swift, Clang and Python 3. Web builds additionally
  need a matching installed Swift WebAssembly SDK.
- `build`: build and package an AdaScript macOS `.app`.
- `export`: the same native pipeline for macOS or Web.

The initial CLI does not implement iOS export, SwiftPM app packaging, preset
management, project creation or a headless gameplay runner. On iPad/iPhone,
validation and Play continue through the embedded mobile services; producing
a separate signed iOS application requires a future Mac/remote build backend.

## SDK and distribution

Only `AdaEditor-Standalone` stages the CLI and `Contents/Resources/BuildSDK`.
The SDK contains the engine/compiler sources, resources, manifests, licenses
and a prebuilt AdaScript compiler. External Swift/Xcode tools and Python 3 are
required; SwiftPM may need network access to resolve package dependencies.
This is a source SDK, not a precompiled player template.

`scripts/stage-build-sdk.py` builds a missing compiler in the staged copy, never
inside the original checkout. The website signing lane signs the compiler and
CLI before the outer application. The CLI reads distribution metadata from its
containing app; a missing/unknown channel remains restricted. App Store and
mobile wrappers do not include this CLI or SDK.

## Automation contract

`--format json` writes one JSON report to stdout. Tool output goes to stderr.
Reports include `schemaVersion`, `cliVersion`, `command`, `ok`, `exitCode`,
`diagnostics`, `artifacts`, `details`, and optionally `project`. Diagnostics
include `code`, `severity`, `message`, and compiler-provided `file`, one-based
`line` and one-based UTF-16 `column`. Human messages may change; integrations
should use codes and fields. Syntax/runtime failures without structured source
locations have a message and code only.

Exit codes: `0` success, `2` invalid command/options, `3` invalid project,
`4` missing environment/toolchain or busy build, `5` failed native build/export,
`130` cancelled.

Unknown, repeated and missing options are rejected. Relative `--project`, SDK,
output and scratch paths resolve from the calling shell's working directory.
The default output is `<project>/Exports/macOS` (or `Web`); default caches are
under `<project>/.ada/cli-build`. Project, output and scratch locks prevent
concurrent CLI writers. Locks release on process exit. The native exporter
stages output and retains the previous valid export when a build fails.

To add a terminal command, create a user-managed symlink to the bundled
`adastudio` executable. Studio does not change PATH or install files automatically.
