# Build & Export settings

## Named build targets

The shared desktop toolbar shows a build-target picker next to the run platform.
Choose **Edit Build Targets…** to create, duplicate, rename or delete targets.
Each target stores its startup scene, Debug/Release configuration, run destination,
arguments, source inclusion/exclusion, resource roots and runtime/plugin settings.
For example, use a Debug target starting at a test scene and a Release target
starting at the game's main scene. Save selects the target open in the editor;
Cancel discards the entire draft. The last target cannot be deleted. Switching is
disabled during builds, running games, debugging, player deployment or recording.

Targets persist in `.ada/project.json` as `buildTargets` with `activeBuildTargetID`.
Existing projects retain their settings and need no migration. Opening the target
editor prepares a Main target from those settings; only Save writes it to disk.
Activating a target projects its settings onto the ordinary `build`, `run`,
`runtime`, `editor.startupScene` and `paths.resourceRoots` fields, so existing
Play/build/export/CLI consumers use the same active configuration. Ordinary
Project Settings saves update the active target. Project identity, input actions,
engine paths and AI settings remain shared. SwiftPM targets also remember the
executable product and apply file/resource selection through the manifest editor.

AdaScript source inclusion/exclusion applies to project sources in local builds
and native exports; library dependencies remain included. Paths are relative to
the project. This does not prune assets or scenes from the exported asset folder.
Native macOS/Web/Android toolbar exports use a stable per-target subdirectory
under `Exports/<platform>/` so targets do not replace each other's output. Toolchain
requirements and supported export platforms are unchanged. The browser shell and
dedicated phone screens do not yet expose the target editor.

### Agent workflow

Load the bundled `ada-build-run` skill for target configuration. Inspect the open
project with `editor.project.context`, then read its `.ada/project.json`. Named
targets are not platform destinations or SwiftPM executable products. To verify
the selected target use `editor.play.start` with `mode: "product"`; scene mode
instead runs the active scene document.

There is no dedicated desktop MCP tool for creating or selecting named targets.
Use the target editor, or available project file tools with the following rules:

- Preserve the schema version, unknown fields, unrelated targets and stable IDs.
  When adding the first target, copy the existing effective project settings.
- Before switching externally, capture the outgoing top-level settings in its
  current target. Set the new `activeBuildTargetID` and project the selected
  target's fields together: `build` → `build`, `run` → `run`, `runtime` → `runtime`,
  `startupScene` → `editor.startupScene`, and `resourceRoots` → `paths.resourceRoots`.
  Updating only an ID does not activate that target's scene or build settings.
- When changing a scene entry, update both the target's `runtime.entry.scene`
  and `startupScene`, plus the active projection. Keep `product` on its target;
  it selects a SwiftPM executable product, not a new package target.
- Target names must be nonempty and unique ignoring case; IDs must be nonempty
  and unique. All targets use the project's build system. Configuration is
  `debug` or `release`. Validation checks inactive targets too.
- Include/exclude paths match files or directory prefixes relative to the project,
  not wildcard patterns. Empty includes mean all project sources; exclusions win.
  Include the project sources imported by the entry code.
- Stop active project tasks and save dirty documents before external edits.
  Reload the project afterwards so the toolbar and workspace agree with disk.

Run `adastudio validate --project <path> --format json` using the installed CLI,
or build through the editor and read its diagnostics. The CLI `--target` flag is
an export platform selector, not a named-target selector. Finally run the product
and verify its startup scene; metadata/build validation alone is not runtime proof.

## Host tools

Open **Settings → Build & Export** to configure tools for the current computer.
These preferences apply across projects; paths are not written into `.adaproject`.
Use **Browse…** for files/directories and **Save Build Settings** to persist edits.
Empty fields use automatic discovery. Path labels check availability, not compiler
versions or successful game builds. External tools require standalone desktop Studio.

Each page has **Rescan** and scans once when first opened. Discovery fills empty
or unavailable paths; working overrides and edits made during a scan are kept.
Use **Save Build Settings** to apply the results. On Windows the scan rereads the
user and system environment from the registry, so tools installed after Studio
started can be found without restarting it. It also checks standard versioned
Swift installations, Android SDK locations, Android Studio's JDK, SDK build-tools
and side-by-side NDKs, CMake, Ninja and Visual Studio build tools. A directory alone
does not establish availability: Android SDK needs adb, JDK needs javac, and NDK
needs its installation metadata. Discovery does not validate compiler versions.
Saving on Windows explicitly writes the preferences to disk, including Android
paths, so closing Studio immediately after Save retains the configuration.

**Install Swift…** on the host platform page opens the official Swift installation
instructions for this OS. **Install Android SDK…** on Android opens Google's
Android Studio setup page. These are guided browser flows, not unattended
installers. Finish installation there, then return to **Rescan** and save.
In Android Studio's SDK Manager, install Platform-Tools, Build-Tools, Emulator and
NDK (Side by side) as needed. An Android emulator still needs an AVD created in
Android Studio. Rescan does not download packages or accept license agreements.

Windows Web and Android builds run through WSL Ubuntu. Run
`script/setup_windows_build_tools.ps1` once to install the managed Linux cross
toolchains. Keep Web's Swift override empty to use the matching managed compiler;
an explicit override must be a Linux executable path. Android discovery and
deployment use the native Windows SDK, while the worker supplies Linux Swift,
SDK/NDK, JDK and Dawn. Native host compiler settings continue to select Windows Swift.

| Page | Tools and current use |
| --- | --- |
| Android | SDK, NDK, JDK, optional Gradle, build-tools version, emulator data, Swift Android SDK/toolchain and Swan/Dawn. Existing APK export and device/emulator Run consume these settings. |
| iOS | Swift, Xcode Developer directory and iOS SDK. Profile storage and path checks are available; Studio does not yet export iOS games. |
| Web | Swift WASM compiler, Swift SDK identifier and optional Tint. Web Run/Export consume these settings. |
| Windows | Swift, CMake, Ninja, Windows SDK and MSVC tools. Native host build commands consume the profile on Windows. Packaging Windows games from macOS is not available. |
| Linux | Swift, CMake, Ninja and C compiler. Native host build commands consume the profile on Linux. Packaging Linux games from macOS is not available. |
| macOS | Swift, Xcode Developer directory, SDK, CMake and Ninja. Native SwiftPM builds/runs/tests and macOS AdaScript export consume these settings. |
| VR / XR | Swift, Xcode Developer directory and visionOS SDK. Profile storage and path checks are available; XR export and other VR runtimes are not yet integrated. |

Android retains the existing `AdaStudio.Android.Tools` preference key. JDK home
affects Java/signing tools; Gradle is optional because the built-in APK exporter
uses Android tools directly. See [Android setup](Android.md).

Changing a native Swift compiler also uses its sibling SourceKit-LSP when present
on subsequent toolchain discovery. Reopen the project to refresh an already-running
language server. Web and Android tools have separate profiles and do not override
the native project compiler.
