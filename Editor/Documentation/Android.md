# Android export and run

Android builds are available in **standalone Ada Studio on macOS**. Projects run
as native Swift applications using Swan/Dawn WebGPU over Vulkan, with Android
NativeActivity and Swift Concurrency. Android API 29 or newer is required.

## Setup

Open **Settings → General → Android** and configure:

- Android SDK (including `platform-tools`, platform 36, build-tools 36.0.0 and `emulator`).
- Android NDK 27 or newer; the validated development setup uses r28c.
- Swift 6.4 executable and the matching official Swift SDK for Android.
- Swan package and its Android Dawn artifact path, relative to Swan.

Standalone builds can bundle Swan and its artifact in the Studio build SDK using
`stage-build-sdk.py --swan-root /path/to/swan`. Swift and the Android SDK/NDK stay
external. See [engine Android setup](../../Tools/Android/README.md) for SDK setup
and `Dawn/build_android.py` for building the required ARM64 or x86_64 variant.

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
chosen destination; the Dawn artifact must include that ABI.

AdaScript uses the existing AOT compiler, metadata validation, scene conversion
and asset staging. Disabled AdaScript view entry points remain unavailable.
Swift projects need an executable AdaEngine `App` target with literal manifest
product/target declarations, or a pre-existing Android native entry point.
Studio prepares the Android shared-library entry point and resource lookup in an
unpublished project copy; it preserves the original Swift sources and manifest.
Unsupported manifest shapes produce an actionable export error.

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
`--swift-sdk`, `--swift-sdks`, `--android-sdk`, `--ndk`, `--swan`, and `--dawn`.
`--abi arm64-v8a|x86_64|all` controls export-only builds. Release optimization still
uses development signing. `--format json` returns the APK path and diagnostics.

## Validation boundary

Swift and AdaScript exports were compiled, signature/alignment checked, installed
and launched on an ARM64 Android emulator. Real Studio toolbar selection, export,
run/stop and AVD boot are checked separately from CLI/service tests. Physical
hardware and x86_64 execution require their own runtime checks.
