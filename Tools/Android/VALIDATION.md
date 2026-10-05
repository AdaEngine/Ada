# Android WebGPU validation — 2026-10-04

- Swift 6.4.0 and matching official Android SDK; NDK r28c; Android SDK 36.
- Local Swan Android branch with Dawn pinned to
  `19696dd088b8ed5804e2f02a8f83f5afdb3e99e3` (Chromium 148.0.7778.97).
- ARM64 Dawn static library built with Vulkan enabled and OpenGL/GLES disabled.
  AndroidDemo and SkeletalGarden dynamic Swift products built and packaged.
  APK signatures and 16 KiB native-library ZIP alignment verified.
- Runtime: isolated ARM64 Android emulator with 16 KiB pages. Logcat identifies
  Dawn backend 6 (Vulkan), Mesa Goldfish GFXStream / llvmpipe adapter.
- Final AdaUI APK rendered text/button. Touch changed the counter to 1; Home/resume
  and another touch changed it to 2; portrait rotation and touch changed it to 3.
  Back/warm recreation retained PID 5291 and another touch changed it to 4.
  Its final log also contains no WebGPU validation errors.
- Skeletal Garden loaded the GLB with 1 skin / 11 joints and Idle/Run/Walk clips.
  Automatic Walk/Run transitions were observed in the rendered scene and logcat.
  Static instancing, skinning, materials, lighting, shadows and reflection passes
  executed without Dawn validation errors in the final runtime log.
- Touch orbit, Home/resume, landscape rotation and Back/warm recreation exercised.
  Warm restart retained PID 5048 and resumed with a fresh native surface.
- Final macOS AdaRender suite: 108 tests passed in 15 suites, including sparse
  vertex buffer regressions. Android Python setup/packaging: 7 passed. Swan Dawn
  configuration/triples: 5 passed. Full Swift suite was not run.
- x86_64 Dawn/Swift runtime, physical Android GPUs, compute, readback and every
  engine feature remain unverified. The helper can build x86_64, but the task's
  installed artifact currently contains only ARM64. ABI validation fails early
  when a requested Dawn variant is absent.
- Swift strict memory safety warnings remain in existing engine/vendored code.

Evidence: `.build-android/evidence/webgpu-ui.png`,
`webgpu-garden-landscape.png`, and `webgpu-garden-logcat.txt`.
The prototype GLES screenshots are historical and do not validate this backend.
Build output, SDKs and development signing keys are task-local and ignored.

Worktrees: AdaEngine branch `codex/android` and Swan branch `codex/android-webgpu`,
under `/Users/vlad-prusakov/.codex/worktrees/android/`. Original checkouts were preserved.

## Revalidation after merging main

- Merged main `e9a0aa485` into `codex/android` (merge `aa4877db6`). Kept the
  updated GardenRobot, landscape, physics, PBR/IBL and animation systems from main,
  with Android resource bundles, automatic movement and touch camera control.
- Rebuilt and installed the ARM64 APK; signature and 16 KiB ZIP alignment passed.
  Emulator process 5814 loaded 2 skins / 43 joints and Idle/Run/Walk/Jump/Fall/Land.
  The landscape reports 48x48m, 8192 terrain triangles, 65 trees, 42 rocks and
  193 grass tufts. The actual frame is `evidence/merge-main-garden.png`.
- Touch orbit, Home/resume and Back/warm reopening passed; the warm launch retained
  PID 5814. `evidence/merge-main-garden-logcat.txt` has zero WebGPU errors.
- Focused host tests: AdaRender 112, garden terrain 2, PBR/character controller 12
  passed (126 total). The final portable mipmap conversion was rerun: 3 passed.
  Android Python setup/packaging tests: 7 passed. Full Swift suite was not run.
- Swift 6.4, its checksum-verified Android SDK, and NDK r28c were restored under
  `.build-android/toolchains/` after the old `/tmp` paths were removed. The local
  launcher environment now points there and uses `.build-android-webgpu-main`.

## Ada Studio Android export/run integration

- Standalone macOS Studio now exposes Build → Export to Android, Android Run
  Destinations, connected device/AVD selection, boot/install/run/stop, and Android
  SDK/toolchain settings. The bundled CLI uses the same export/launch services.
- Exported real Swift Counter and AdaScript AOT projects; both signed APKs passed
  signature/16 KiB zip alignment, installed, reached engine startup and ran on
  the ARM64 emulator. Native AdaScript metadata/scene conversion remained in the
  existing exporter. Per-project signing keys survive subsequent exports.
- Tested the real installed Studio bundle via its MCP UI API: destination
  selection, toolbar Run and Stop, Android source SDK packaging, and complete
  cold boot of the task-owned AdaStudioAndroidProof AVD on emulator-5554.
  The installed AOT process 4197 logged Native game ready with no WebGPU errors.
  Stop returned Studio to Ready and removed that app process, retaining the AVD.
- Final focused editor suites: 16 tests passed; the opt-in real APK integration
  test separately passed. Python APK setup/selection: 8 passed. Bundled build SDK
  staging/relocation: 2 passed. 18 offline guides passed consistency checks.
- A user AVD booted successfully but lacked installation storage; its app data
  was preserved and the AVD was stopped again. Installation/run verification used
  the empty task AVD instead. Physical device and x86_64 runtime remain unverified.
- UI interaction evidence: `.build-android/studio-android-final-tests.log` and
  the installed Studio MCP Run/Stop checks. Android scene:
  `evidence/studio-export-script-android.png`; runtime log:
  `evidence/studio-ui-avd-logcat.txt`.
