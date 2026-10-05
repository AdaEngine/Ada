# Native Android apps

AdaEngine can build a native Swift shared library, package it in a debug-signed
APK, install it, and launch it on an authorized device or emulator. The host uses
Android NativeActivity, native WebGPU (Swan + Dawn/Vulkan), Choreographer, and Swift Concurrency.
No Kotlin translation or browser runtime is involved.

## Prerequisites

- Open-source Swift **6.4.0** and the exactly matching Swift SDK for Android.
  The Apple compiler included with Xcode is not a substitute for this SDK.
- Android SDK platform 36, build-tools 36.0.0, and platform-tools (`adb`).
- Android NDK r28c (27 or later is accepted by the Swift SDK setup script).
- JDK 17 or later for `keytool` and `apksigner`.
- Android API **29+** with Vulkan support; arm64-v8a or x86_64.
- An Android Dawn artifact built from the exact revision used by the local Swan bindings.

The root package keeps its Swift 6.2 minimum. Android uses the open-source 6.4.0
toolchain explicitly; other platforms do not need to change their default Swift.

Install the open-source Swift 6.4.0 toolchain from [Swift downloads](https://www.swift.org/install/),
set `SWIFT_ANDROID_SWIFT` to its absolute `swift` executable path, then install the
[official Android SDK](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html):

```sh
"$SWIFT_ANDROID_SWIFT" sdk install \
  https://download.swift.org/swift-6.4.0-release/android-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_android.artifactbundle.tar.gz \
  --checksum 21fb555122a3d801ad943d48df7ebffdd8824de61c25c180bb792d3edaee0b43
```

Set `ANDROID_HOME` to the Android SDK and `ANDROID_NDK_HOME` to your NDK.
Run the SDK's `swift-android/scripts/setup-android-sdk.sh` with that NDK set.
On macOS installed SDKs normally live in
`~/Library/org.swift.swiftpm/swift-sdks`; Linux commonly uses `~/.swiftpm/swift-sdks`.
A locally extracted artifactbundle is also supported through `--swift-sdks`.

Set `SWIFT_ANDROID_SWIFT` to the **absolute path** of the 6.4.0 `swift` binary,
or pass `--swift /path/to/swift`. This avoids changing the global Swift default.
For another toolchain release, pass its matching `--swift-sdk` explicitly.

## Swan and Dawn

Use the local Swan checkout containing Android support, with its matching Swift 6.4 toolchain.
Build Dawn using Python 3.10+, CMake and Ninja:

```sh
cd /path/to/swan
ANDROID_NDK_HOME=/path/to/ndk python3 Dawn/build_android.py --arch arm64 --jobs 6
# Add --arch x86_64 to build both ABIs in one bundle.
export ADAENGINE_SWAN_PACKAGE_PATH=/path/to/swan
export SWAN_LOCAL_DAWN=Dawn/dist/android.artifactbundle
export SWAN_RUNTIME_ONLY=1
```

`SWAN_LOCAL_DAWN` is relative to the Swan package root. The runtime profile uses
checked-in native bindings without resolving the generators' SwiftSyntax dependencies.
The script pins Dawn to the bindings' revision, enables Vulkan, and disables Dawn's
OpenGL/GLES backends. It strips debug data only from packaged copies.

## Build and run

From the AdaEngine repository root:

```sh
python3 Tools/Android/android.py doctor
python3 Tools/Android/android.py devices
python3 Tools/Android/android.py build
python3 Tools/Android/android.py run --serial emulator-5554
# Convenience wrapper; optionally reads task-local .build-android/local-env.sh
Tools/Android/run_demo.sh --serial emulator-5554
```

`run` builds, installs, and starts the app. To reuse an APK:

```sh
python3 Tools/Android/android.py run \
  --apk .build-android/apk/AndroidDemo-debug.apk --serial emulator-5554
```

Build a matching Dawn variant before selecting another ABI. Select `--abi x86_64` for an x86 emulator, or `--abi all` to package both 64-bit
ABIs. `--configuration release` optimizes Swift code, but still produces a
**debug-signed** APK for development. Store distribution signing/AAB generation
is outside this tool. Build output and the local development key live under
`.build-android/`; shared `.build` caches are not touched.

The packaging step resolves the transitive ELF runtime dependencies, rejects a
missing library, includes complete SwiftPM resource bundles, and verifies the
APK signature and 16 KiB native-library zip alignment. APK copies have debug
sections stripped; the original Swift build/SDK files retain their DWARF. The NDK and matching
Swift SDK supply the required C++/Swift runtimes.

The existing 3D animation scene also has an Android entry point:

```sh
Tools/Android/run_demo.sh --product SkeletalGarden \
  --application-id org.adaengine.android.garden --label "Skeletal Garden" \
  --serial emulator-5554
```

On Android it automatically walks/runs the character. Desktop controls stay available
on desktop builds.

## Your own app

Define a SwiftPM **dynamic library** product. Its exported Android entry point
starts an ordinary AdaEngine `App` through an actor-isolated factory:

```swift
import AdaEngine

#if os(Android)
@_cdecl("ada_android_start")
public func startAndroidApp() {
    AndroidRuntime.start { MyGame() }
}
#endif
```

Package and launch it with:

```sh
python3 /path/to/AdaEngine/Tools/Android/android.py run \
  --package /path/to/MyGame --product MyGameNative \
  --application-id org.example.mygame --label "My Game"
```

For the app target's own SwiftPM resources, pass
`AndroidResourceBundle.bundle(named: "PackageName_TargetName")` as `assetBundle`
to `WindowGroup` or `DefaultAppWindow` on Android. See `Demos/AndroidDemo`.
The packaging tool extracts bundles from the APK into app-private storage
before engine bootstrap; engine shaders/fonts use the same path. Writable data
and caches also stay inside the app's private files directory.

## Runtime boundaries

- One native window/activity per process. Its Swift app context is retained
  while Android destroys/recreates the activity; frame updates suspend on pause
  and resume when a display surface is available.
- Swift `MainActor` jobs run on Android's main looper. The C bridge uses Swift's
  executor runtime hook; changing toolchain versions requires validating this
  integration again. `DispatchQueue.main` is not an Android UI dispatch API.
- Stable Android pointer IDs become stable engine touch IDs; pause cancels
  active touches. Android Back finishes the activity.
- The existing WebGPU backend supplies rendering, textures, buffers and shaders.
  Android uses an acquired `ANativeWindow` and a Vulkan adapter. Surface loss detaches
  the GPU swapchain; recreation obtains a fresh native window lease.
- Native shaders are compiled to SPIR-V on-device and imported by Dawn; no Tint CLI
  runs inside the APK. Dawn's native SPIR-V derivative option preserves existing GLSL
  sampling behavior. Intermediate BGRA targets are composited into Android's RGBA output.
- Android URL opening, native alert dialogs, soft keyboard/text composition,
  hardware keyboard/gamepad input, native filesystem watching, and multiple native windows need additional
  host implementations. The current touch/AdaUI demo does not exercise those APIs.

For diagnostics:

```sh
adb -s emulator-5554 logcat -s AdaEngine AndroidRuntime DEBUG
```
