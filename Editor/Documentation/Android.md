# Android export and run

Android builds are available in **standalone Ada Studio on macOS and Windows**. Projects run
as native Swift applications using SAGA Vulkan, with Android
NativeActivity and Swift Concurrency. Android API 29 or newer is required.

## Setup

On Windows, install the native Android SDK with platform-tools and emulator
(Android Studio provides these), enable WSL with Ubuntu, then run
`./script/setup_windows_build_tools.ps1 -AndroidOnly` from the engine root.
The worker prepares Linux Swift 6.4, the matching Android Swift SDK, NDK r28c,
and JDK 17 for ARM64 and x86_64. Existing Android SDK licenses
are copied from the Windows SDK. The Windows SDK setting selects native
adb/emulator; compilation uses the managed Linux tools. APKs are written back
to the project's export folder. Use an emulator with Vulkan support.

For an API 35 x86_64 image installed through Android Studio,
`./script/create_windows_android_emulator.ps1` creates the optional
`AdaStudio_API35` AVD without changing existing AVDs.

Open **Settings → Build & Export → Android** and configure:

- Android SDK (including `platform-tools`, platform 36, build-tools 36.0.0 and `emulator`).
- Android NDK 27 or newer; the validated development setup uses r28c.
- JDK home (Android Studio's bundled JDK is detected automatically), and optionally a Gradle executable for external tooling.
- Android build-tools version, if different from the default 36.0.0.
- Swift 6.4 executable and the matching official Swift SDK for Android.
- Optional path to a local SAGA checkout. An empty field selects the published revision through SwiftPM.

Use **Browse…** to choose paths, then **Save Build Settings**. Settings apply to this
computer across all projects. The built-in APK exporter uses Android tools directly
and does not require Gradle. The neighboring platform pages configure Web and native
host tools and identify export paths that Studio does not yet provide.

Swift and the Android SDK/NDK stay external to the Studio build SDK. See
[engine Android setup](../../Tools/Android/README.md) for installing those tools.

Create an AVD in Android Studio to use an emulator. For a physical device, enable
USB debugging, connect it, and authorize the computer on the device.

## Run

1. Open the project and save changes.
2. Choose **Android** in the toolbar's Run Destination menu.
3. Choose a connected device/emulator or an available AVD. **Refresh** rescans them.
4. Press **Run**. Studio boots a stopped AVD if needed, chooses the device ABI,
   exports an APK, installs it, and waits for the engine to start.
5. **Stop** stops that project's Android package. It leaves the emulator running.

Unauthorized and offline devices cannot be selected for Run. Errors and build
output appear in Studio's existing Build Output/activity panels.

## Export

**Build → Export to Android…** writes `Exports/Android/android/<product>-debug.apk`.
The default export is ARM64. Run automatically selects ARM64 or x86_64 for the
chosen destination.

AdaScript uses the existing AOT compiler, metadata validation, scene conversion
and asset staging. Disabled AdaScript view entry points remain unavailable.
Swift projects need an executable AdaEngine `App` target with literal manifest
product/target declarations, or a pre-existing Android native entry point.
Studio prepares the Android shared-library entry point and resource lookup in an
unpublished project copy; it preserves the original Swift sources and manifest.
Unsupported manifest shapes produce an actionable export error.

Keep startup code platform-independent:

```swift
import AdaEngine

@main
struct Garden: App {
    var body: some AppScene {
        DefaultAppWindow(assetBundle: .module)
    }
}
```

Studio removes `@main` in the export copy and generates `ada_android_start`,
which starts that app through `AndroidRuntime`. No Android startup function or
separate desktop `main` wrapper is needed in the project. Top-level, nongeneric
`struct`, `class` and `enum` App types are supported, including private types.
The bridge stays in the app's file, so explicit target `sources` lists work.
An existing `ada_android_start` is preserved; Studio still adapts resource lookup.
The GUI and CLI use the same generation path.

Exports publish atomically only after packaging succeeds. A failed export leaves
the previous APK intact. Per-project development signing keys live under
`.ada/android-signing/`; preserve them to update an already-installed debug app.
These are **development APKs**. Play Store signing and AAB packaging are separate.

## CLI

The same services are available from the bundled `adastudio` CLI:

```sh
adastudio export --project /path/to/game --target android --configuration debug
adastudio export --project /path/to/game --target android --device emulator-5556
adastudio export --project /path/to/game --target android --emulator Pixel_9
```

Swift projects can select `--product Game`. Tool overrides include `--swift`,
`--swift-sdk`, `--swift-sdks`, `--android-sdk`, `--ndk` and `--saga`.
`--abi arm64-v8a|x86_64|all` controls export-only builds. Release optimization still
uses development signing. `--format json` returns the APK path and diagnostics.

## Validation boundary

Earlier Swift and AdaScript export checks covered compilation, signing, alignment,
installation and launch on an ARM64 emulator. Check Vulkan rendering and surface
recreation on the intended device or emulator. Studio toolbar selection,
export, run/stop and AVD boot have separate checks from CLI/service tests.
