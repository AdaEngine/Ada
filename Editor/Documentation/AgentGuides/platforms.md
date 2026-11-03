# Packages, Platforms and Distribution

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

## Package and workflow

- `Editor/` is a separate Swift 6.2 SwiftPM package, depending on AdaEngine by
  local path. Run editor builds/tests from this directory.
- Release wrappers include Studio for iOS/iPadOS, macOS App Store, native visionOS
  and standalone macOS, plus the separate iOS AdaPlayer. `fastlane/SETUP.md`
  documents the `upload_xcode` targets `ios`, `macos`, `visionos` and `player`.
  The visionOS wrapper uses the shared workbench and a dedicated layered icon;
  archive/upload validation does not establish visionOS interaction parity.
- Shared editor UI uses AdaUI. Native app wrappers and mobile-specific screens
  have separate platform boundaries; do not assume desktop/mobile feature parity.
- Windows Studio is built/launched with [../script/run_studio_windows.ps1](../../../script/run_studio_windows.ps1).
  Windows distributions are always Standalone. The launcher builds Release and
  stages the complete SDK, compilers, runtime DLLs and resources through the release
  packager before opening it. Do not launch a bare SwiftPM executable or a partial
  staging folder for user validation; Android and Web require the bundled SDK.
  It prepares pinned Tint and a task-local Gravity binding with C-owned UTF-8
  strings, selecting it through `ADAENGINE_GRAVITY_PACKAGE_PATH`. Manual Windows
  builds/tests must use that override too. Native project/asset file pickers,
  RGB color selection (inspector alpha), HTTPS downloads, local Run and D3D12
  readback are implemented. Windows also has a menu row, native Settings window,
  a theme-coloured Settings caption using the shared Windows window controls,
  contextual cursors, Cloud browser PKCE sign-in with Credential Manager, and
  WinSock/DNS-SD AdaPlayer pairing (including manual host:port). Apple in-app
  purchases remain Apple-only. WebAssembly and Android compilation use the WSL
  worker prepared by `../script/setup_windows_build_tools.ps1`; adb/emulator run
  natively on Windows. See [README.md](../../README.md#Windows).
- [Package.swift](../../Package.swift) owns package dependencies and resources;
  [project.yml](../../project.yml) owns XcodeGen app configuration.
- Windows release CI uses `../script/build_studio_windows.ps1` and
  `../script/package_studio_windows.py`. It publishes an x64 ZIP and SHA-256 on
  GitHub Release publication; manual/PR builds retain Actions artifacts. Packaging
  bundles Swift/Dawn runtime DLLs, resources, Tint and a relocatable `BuildSDK`
  beside the executable. It checks PE imports and launches the tools with a clean
  PATH. Windows signing and external host/export toolchains remain separate.
- Desktop installation uses `../script/install_studio_windows.ps1` and
  `../script/install_studio_macos.sh`: build Release or copy a complete supplied
  distribution to the current user's Windows Programs folder or `/Applications`.
  macOS source builds use the explicit `AdaEditor-Standalone` scheme and local
  ad-hoc signing. Native macOS installation tests run in macOS CI.
- Build & Export scans host tools on page entry and provides Rescan plus official
  Swift/Android setup links. Discovery fills missing/broken paths in the settings
  draft, preserves valid overrides, and requires Save Build Settings to persist.
  Rescan, setup and Browse use compact themed buttons with borders and hover feedback.
  Windows discovery rereads registry environment and standard install locations;
  native Windows tools must not fill WSL Web compiler/Tint fields. Setup links
  open browser guides; they do not perform unattended installation.
- Keep mocks, fixtures, and QA harnesses in test targets or separate executables.
  Do not add test-only objects or QA launch hooks to the main app, including Debug builds.
- Linux Standalone uses X11/XWayland and Vulkan. Follow
  [../Documentation/Linux.md](../../../Documentation/Linux.md) and launch through
  `../script/run_studio_linux.sh` to stage resources, runtime libraries and BuildSDK.
  Use the bundled Gravity compiler and staged Linux Swan overrides for builds/tests;
  native dialogs require Zenity. The initial Linux workbench/local Run port does
  not establish remote AdaPlayer, ACP, debugger, Cloud or cross-export parity.
- Use an isolated scratch/module cache when necessary; never delete the shared
  `.build`. Preserve unrelated engine, demo, and editor changes.
- Desktop builds accept `--editor-project=<absolute-path>` to open the
  production workspace directly. `adastudio <directory>` resolves the caller's
  path, validates the project and launches a new workspace window.
- Public scripting terminology is **AdaScript**. `Gravity*` names are internal
  compiler, VM, and language-tooling implementation names.

## Boundaries and incomplete paths

- `EditorDistribution` gates capabilities: Swift projects require standalone;
  App Store distributions expose AdaScript templates. External process tooling
  and local ACP agents must not be assumed available on iOS.
