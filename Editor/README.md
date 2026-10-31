# AdaEditor

AdaEditor is a standalone SwiftPM package for the AdaEngine editor. It contains the `AdaEditor` executable target, UI resources, and tests for editor logic.

## Structure

- `Package.swift` — the editor package manifest.
- `Sources/AdaEditor` — the editor application's source code.
- `Sources/AdaEditor/Assets` — editor assets, including images and fonts.
- `Tests/AdaEditorTests` — editor tests.
- `project.yml` — the XcodeGen configuration for generating the Xcode project.

## Dependencies

The package depends on:

- the local `AdaEngine` package in the parent directory (`.package(path: "..")`).

## Building and Testing

Run the following commands from the `Editor` directory:

```bash
swift build
swift test
```

### Linux

Studio Standalone can be built for X11/XWayland, including WSLg, with Swift 6.3.2
and Vulkan. See [Linux setup and validation](../Documentation/Linux.md) for the
pinned Swan/Dawn, Tint and bundled compiler setup, then run
`bash script/run_studio_linux.sh` from the engine root. It builds and stages the
editor, resources, Swift runtime and source BuildSDK before launching. File
dialogs require Zenity; Linux is the local Run destination. This initial port
does not establish parity for every desktop service or export target.

### Windows

Inspector fields support [explicit subgroups](Documentation/InspectorGroups.md)
with up to four levels through `@export(group: "Camera/Auto Exposure")` in AdaScript
or `@Export(group: "Camera/Auto Exposure")` in Swift components. Scene hierarchy
includes name search, empty parent groups and a resizable, remembered width.

Use Swift 6.3 or newer for the Swan/WebGPU dependency, Visual Studio C++ Build
Tools, Python 3, CMake and Ninja. From the engine root, run:

```powershell
./script/run_studio_windows.ps1
```

The launcher verifies/builds the pinned Tint shader compiler and prepares a
pinned Gravity binding with native string allocation and UTF-8 lengths under
`.build-tools/gravity-windows`; it never edits shared SwiftPM checkouts. It sets
`ADAENGINE_GRAVITY_PACKAGE_PATH`, builds Release and opens a complete Standalone
folder under `.build-tools/standalone-studio`. Windows Studio is always Standalone.
The launcher uses the release packager to include and verify the build SDK,
AdaScript compiler, Tint, resources and runtime DLLs. Launching the bare SwiftPM
executable does not provide that export toolchain.
Web/Android cross-build caches stay inside WSL at
`~/.local/share/AdaStudio/BuildTools/builds`. Windows-mounted scratch paths are
redirected there to avoid slow SwiftPM file operations over the Windows mount;
an explicit Linux scratch path is preserved.
Use the same dependency override for manual Windows builds/tests:

```powershell
./script/build_studio_windows.ps1 -Configuration debug
swift test --package-path Editor --skip-build --filter EditorWindowsCompatibilityTests
```

`-ScratchPath D:/Temp/ada-studio-build` selects an isolated
SwiftPM cache when the shared cache belongs to another Swift toolchain.
Local Run uses the Windows destination for SwiftPM and embedded AdaScript
projects. Project/folder selection, multi-file asset import and RGB color dialogs
use Windows controls; inspector alpha remains editable. HTTPS clients support
bounded streaming downloads and cancellation. Rendering/readback uses Dawn D3D12.
The main window uses a themeable client-drawn title bar with application menus,
Ctrl shortcuts and native minimize/maximize/close commands. Empty title-bar space
drags the window; double-click and right-click retain Windows caption behavior.
AdaUI's transparent overlay title-bar configuration and `WindowCaptionControls`
also support custom layouts. Studio includes a native Settings window and
contextual cursors. Ada Cloud opens the default browser for PKCE sign-in and
stores the session in Windows Credential Manager. Apple in-app purchases still
require Apple platforms. AdaPlayer uses native WinSock and Windows DNS-SD;
manual `host:port` connection is available when discovery is unavailable.
`AdaEditor.exe --ada-player` opens the Windows player.

Windows Studio follows the WebGPU FIFO display cadence using a high-resolution
frame clock. Release FPS and frame-interval measurements, hardware details and
PresentMon reproduction commands are in [Windows performance](Documentation/WindowsPerformance.md).

Windows Agent Chat supports local ACP agents. Open **Settings → Agents**, choose
**Refresh**, then connect a discovered adapter or use **Install & Connect** from
the ACP Registry. Native Windows distributions are preferred when available;
npm adapters require Node.js and Python adapters require uv. Regular Codex/Claude
CLIs need their ACP adapter. Manual commands can use an `.exe`, a JavaScript entry
point, or an npm-generated `.cmd` launcher; arbitrary batch scripts should be
launched through an explicitly configured shell executable.

ACP sessions support streamed replies, model/configuration selection, permissions,
project file access, bounded terminal output, cancellation, session restoration,
A2UI cards and the live Studio MCP tools. Provider authentication remains with the
agent's own account setup. Agent executables and terminal children run in Windows
jobs and terminate with their owning process; no console window is opened.

Windows release archives are built by **Windows Studio release** in GitHub Actions
on release publication (including prereleases). The workflow builds Release with
Swift 6.3.1 on Windows Server 2022, tests SDK relocation, checks the DLL dependency
closure and smoke-tests the packaged tools without a Swift installation on PATH.
It attaches `AdaStudio-<tag>-windows-x86_64.zip` and `.zip.sha256` to that release.
Pull requests changing release tooling and manual workflow runs produce downloadable
Actions artifacts only. Existing release assets are never overwritten on a rerun.

Extract the whole archive and open `AdaEditor.exe`. Swift runtime DLLs, Dawn/DXC,
resources, Tint and the AdaScript source build SDK are included. The archive is
currently unsigned; native project builds still require Swift/Visual Studio C++
tools, and Web/Android exports require WSL and their SDKs. To package locally:

```powershell
$studioBin = (& ./script/build_studio_windows.ps1 -Configuration release | Select-Object -Last 1).Trim()
python script/package_studio_windows.py --bin "$studioBin" --compiler-root "$env:ADAENGINE_GRAVITY_PACKAGE_PATH" --tint "$env:TINT_EXECUTABLE" --version local
```

WebAssembly and Android builds use a Linux worker under WSL (Ubuntu). Prepare
the matching Swift SDKs, pinned Tint, Android SDK/NDK and Swan/Dawn with:

```powershell
./script/setup_windows_build_tools.ps1
```

The setup also accepts `-WebOnly` or `-AndroidOnly`. It installs tools in the WSL
user's `~/.local/share/AdaStudio/BuildTools`; native Windows adb/emulator are
used for device discovery, installation and launch. See
[Android setup](Documentation/Android.md). Web Run serves the export with
WebGPU isolation headers and opens it in the browser. Build logs stay in the
worker's build cache and compiler errors are repeated at the end of failures.

Portable AdaScript exports select the full VM for modules containing `static`
declarations, preserving the editor's shared class state. Other modules retain
the native AOT path. The export marker records `runtime: interpreted` or
`runtime: aot`; imported helpers are resolved and ordered before native compilation.

## Generating the Xcode Project

Install XcodeGen if it is not already installed, then run:

```bash
cd Editor
xcodegen generate
open AdaEditor.xcodeproj
```

The generated project uses the local `AdaEditor` SwiftPM package. To build and run the editor, select the `AdaEditor (Editor)` scheme that Xcode creates for the package's executable product.

## Command Line

The standalone macOS bundle also includes the `adastudio` command-line entry for
project inspection, validation and AdaScript app builds. See [CLI](Documentation/CLI.md)
for commands, SDK prerequisites and the JSON contract. iOS uses its existing
embedded validation and Play services.

## TestFlight

Fastlane can build a signed iPadOS IPA (`bundle exec fastlane ios build`) or build
and upload it (`bundle exec fastlane ios beta`). See
[TestFlight setup](fastlane/SETUP.md) for signing prerequisites, versioning, and
private environment variables. No credentials belong in the public repository.

## Offline Documentation

Open **Help > AdaEngine Documentation**, or use the **Documentation** button on the welcome screen or editor toolbar. The native SwiftUI reader includes full-text guide search, section navigation, Back/Forward history, and copyable code examples. On macOS it opens a reusable window; on iPadOS it opens an in-app reader with a Done button.

The bundled library contains the editor guide and substantive Markdown articles from the AdaEngine and AdaScripting DocC catalogs. It works without internet or a source checkout. Generated API reference pages and external websites are not bundled; external links are labeled **Internet**.

After changing a source article, regenerate and verify the checked-in snapshot:

```bash
python3 scripts/update-offline-documentation.py
python3 scripts/update-offline-documentation.py --check
```

The snapshot lives in `Sources/AdaEditor/Assets/Documentation/catalog.json` and ships through the existing SwiftPM `Assets` resource copy, including the macOS and iPadOS app wrappers. The generator preserves code examples, removes DocC presentation metadata, and validates internal article links.

### Android

Standalone macOS and Windows Studio support **Build → Export to Android…** and Android
Run Destinations with connected devices and AVDs. Swift and AdaScript projects
use the native Swift/WebGPU Android host. Configure **Settings → Build & Export → Android** and
see [Android export and run](Documentation/Android.md).

Build & Export also groups iOS, Web, Windows, Linux, macOS and VR / XR tool paths.
See [build tool settings and platform availability](Documentation/BuildExport.md).

Official games and feature examples are available from the HUB Samples section.
See [Examples.md](Documentation/Examples.md) for downloading editable projects and local catalog development.

Desktop projects can use **Git** or **Lore**, selected during project creation
and in the Source Control panel. See [Source control](Documentation/SourceControl.md)
for supported platforms, repository behavior and Windows build preparation.
