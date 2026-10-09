# Build & Export settings

Open **Settings → Build & Export** to configure tools for the current computer.
These preferences apply across projects; paths are not written into `.adaproject`.
Use **Browse…** for files/directories and **Save Build Settings** to persist edits.
Empty fields use automatic discovery. Path labels check availability, not compiler
versions or successful game builds. External tools require standalone desktop Studio.

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
