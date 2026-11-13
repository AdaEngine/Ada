# SAGA renderer cutover delivery sequence

This implements the [approved cutover design](../Designs/saga-renderer-cutover.md). Keep the existing runtime selection until each replacement is demonstrated. The budgets below are estimates for one reviewable change; split larger implementations by behavior. Review the combined result independently after all tasks, as requested.

Current delivery scope: finish SAGA Metal and browser WebGPU. Windows, Linux, and Android Vulkan
remain follow-up work. Do not change their default renderer or remove their build dependencies
as part of this delivery.

| Change | Depends on | Integration and evidence | Approximate budget |
| --- | --- | --- | --- |
| Publish a reusable SAGA browser host | SAGA baseline | Add a library and injectable transport; run the existing browser diagnostic plus deferred canvas tests. | 600 lines, excluding source moves |
| Complete SAGA Vulkan presentation contract | SAGA baseline | Add surface attachment, resize and retirement to the shared device; test Win32 and Xlib presentation, then Android separately. | 600 lines per platform slice |
| Pin matching SAGA revision in AdaEngine | Browser and Vulkan contracts | Exercise dependency resolution in a clean checkout; use the existing native opt-in flag until verified. | 300 lines |
| Verify browser WebGPU | Matching revision | Run a clean browser export, the smoke golden, and a presented-frame readback with the matching host assets. | 600 lines |
| Verify and enable Windows Vulkan (follow-up) | Matching revision | Run Studio and native readback with Vulkan. Keep Windows DLSS support subject to the approved design. | 600 lines |
| Verify and enable Linux and Android Vulkan | Matching revision | Run native windows and Android export with pause/resume and surface replacement before changing defaults. | 600 lines per platform slice |
| Integrate Apple SAGA Metal | Matching revision | Verify offscreen 3D, real window presentation and resizing, and shader output on Apple hardware before changing defaults. | 600 lines per behavior slice |
| Complete WESL and Shader Graph cutover | Existing shader migration and verified runtime paths | Switch source variants and bake/archive paths after artifact, readback and export checks. Preserve graph parameters and reject legacy source-only GLSL with a migration diagnostic. | 600 lines per shader family |
| Remove legacy render and compiler wiring | All default paths and shader checks | Remove the temporary flag and Swan/Dawn, GLSL and Tint dependencies where unused. Update DocC and tooling guides and verify documented examples and exports. | 600 lines per removal slice |

## Companion revision and validation

The local SAGA candidate is `8bbf2cf7bcabf561df4db1eda8656457f6ef069f` on
`codex/adaengine-compatibility`, based on `cc2aacc61116449950c46de45e0b3bf3a26aa77b`. It adds
`SAGAWebHost` with an injected transport, deferred canvas attachment and frame readback, and Vulkan
surface attachment and retirement. The local checkout is `.build-tools/saga-companion`; the Git
bundle at `.build-tools/saga-adaengine-compatibility.bundle` imports the two commits into a SAGA
checkout that has the base commit. Use `ADAENGINE_SAGA_PACKAGE_PATH` to build against the candidate.

- Built the browser diagnostic target and AdaRender for WASM with Swift 6.3.2. Built SAGAVulkan
  locally and ran three SAGA presentation contract tests on macOS.
- Chromium with hardware WebGPU presented a BGRA texture through the deferred canvas and returned
  the expected RGBA bytes. The AdaEngine `export-web` command built AdaWebPlayer; the packaged
  `SAGASmoke` scene passed the existing browser golden (mean error 0.46 / 4, bad pixels 1.41% / 2%).
- The candidate is local. Pin a reachable revision in release and CI once it is published. Native
  presentation still needs target-platform verification. In particular, Windows currently destroys
  the HWND after removing the logical window; coordinate destruction with queued Vulkan retirement
  before enabling the backend by default. Linux and Android surface lifetime and Apple backend
  acceptance remain open.

The Metal and Web publication candidate is `8be633b5be0f747e0aa4e030fcad03c4ca17908f` on
`codex/adaengine-metal-web`. The bundle at `.build-tools/saga-metal-web-release.bundle` contains
the Metal and Web changes and the shared presentation contract. Its relevant files are identical
to the validation checkout at `dc597ff539572846edf4c821fb3b14888c8a4b2a`; the separate candidate
omits the Vulkan backend changes. The SAGA Metal compute readback and surface ownership tests passed on
an Apple M3 Pro with graphics access. AdaEngine's `SAGAMetalWindowTests` read back the expected
pixels and received positive presentation timestamps at both window sizes. All five
`PixelPerfectMetalTests` passed on SAGA Metal, covering sprites, exact scaling, and UI composition.
The Metal option resolves no Swan dependency.

The initial 3D run reproduced a stack overflow in SAGA's MSL writer for SSAO. After replacing
recursive expression and cast emission, both `Render3DGPUTests/SagaNative` cases passed, including
the Shader Graph material. The stored sphere reference differs from both current renderers.
Against a fresh legacy Metal run on the same GPU, SAGA's frame differs in 50 of 1,228,800 channel
bytes, by one step at most; no pixels exceed the two-step tolerance. The full legacy golden suite
also reports a wireframe mismatch and a missing shaded-wireframe reference. These failures do not
establish a regression in SAGA. Keep the checked-in references for separate baseline maintenance.

The 87 targeted expression, conversion and compiler-budget tests passed. The freshly exported
`AdaWebPlayer` also passed the existing `SAGASmoke` golden in Chromium again (mean error 0.46 / 4,
bad pixels 1.41% / 2%). The final companion commit adds package deployment targets and excludes
hardware-only diagnostics on simulators; `SAGAMetal` builds for iOS and tvOS simulators. This
was followed by successful `AdaEngine` builds against the iOS Simulator, tvOS Simulator, and Apple
TV SDKs with SAGAMetal enabled. The tvOS build needed platform guards for pasteboard, edit menu,
pointer interactions, and screen brightness. The standard build with legacy Metal also passed
against the Apple TV SDK. The temporary iPhone simulator app launched through
SAGAMetal and logged a rejected text pass because its GPU does not support filtering 32-bit float
textures. The font loader now uses RGBA16F for the GPU upload when filtering RGBA32F is unavailable.
The corrected iPhone simulator run displayed the text and colored UI. The renderer log confirmed
the text pass and presentation completed. The Apple TV target also compiles with this fallback.
The iPhone 3D scene also displayed a lit sphere and its shadow. The PBR shader packs the four
material scalars into one interpolator, and the shadow passes use integer loads from the 32-bit
atlases. The iPhone log showed presentation and no SAGA errors. On tvOS Simulator 26.2, an app
built with SwiftPM and the tvOS 26.5 SDK displayed text and the 3D scene with shadows. The
1920×1080 capture and SAGA queue log confirm the 3D presentation. Physical Apple TV runtime
verification remains open.

The current AdaEngine checkout was rebuilt with the Metal and Web candidate using Xcode 26.6
and the tvOS 26.5 device and simulator SDKs. The build excludes UIKit pointer and edit-menu
APIs on tvOS and uses the clipboard's in-process fallback. The rebuilt tvOS client ran the
3D shadow scene on the Apple TV Simulator, with SAGA pipeline logs and a captured frame.

The Web exporter uses the same resolved SAGA package for Swift code and JavaScript assets. The
release candidate export passed the browser golden, and the final WASM and JavaScript files matched
the checked artifacts byte for byte. A fresh export after the font atlas fallback passed the same
golden with unchanged error metrics. A further export after the PBR and shadow changes passed
with the same metrics. The macOS incremental build with Swift 6.3.2 reproduced a SIGBUS. A clean
build with Xcode Swift 6.3.3 passed PBR parity, Shader Graph and the WESL library tests. The PBR
and Shader Graph cases and all five 2D cases also passed in that build with diagnostics disabled.
The compatibility branch has not been published.

The command completion regression reproduced early callbacks on both a command buffer and an empty
frame fence. Both cases now pass. MovieMaker ran on SAGAMetal and verified the pixels of two
recorded frames across a camera cut. A fresh Web export also passed the browser golden after the
completion change.

The failure-path regression reproduced two additional faults when SAGA device creation throws:
pending completion callbacks were dropped and an already-attached window surface was not removed.
The queue now runs cleanup in submission order without a device and completes skipped command
callbacks. Both failure cases and the successful submission-retirement cases passed.

## Default renderer rollout

The rollout selects SAGAMetal by default on macOS, iOS, and tvOS, pins SAGA for Metal and
Web builds, and updates Apple CI and tooling. The legacy Metal switch and the local SAGA
checkout override remain available during the transition.
The Apple validation job builds the default renderer for macOS and the Apple TV SDK.
Its legacy Metal comparison explicitly selects that renderer.
The iPad job checks out AdaEngine under its SwiftPM package identity and uses the pinned
portable Sloppy runtime at `0d8fd03d0269a480b6af3fb4f40333c319e2c398`. The newer runtime
checkout imports SloppyA2UI without declaring it in the portable package. Separating Apple
and Android product conditions makes Xcode link the portable products into iPad Studio.
The iPad simulator build succeeded with the pinned SAGA and Sloppy checkouts. On iPadOS
Simulator 26.3, Studio compiled the SAGA UI, text and upscale pipelines and displayed the
project launcher. The CI script waits for the upscale pipeline before taking a screenshot.

Two isolated source copies resolved `8be633b5be0f747e0aa4e030fcad03c4ca17908f` through a local
Git mirror with the canonical GitHub URL in their lockfiles. The macOS copy selected SAGAMetal
without a renderer flag and presented frames before and after a resize. The window check runs
with its explicit smoke flag and skips otherwise. The Web copy exported the player, shipped
the exact JavaScript assets from the pinned revision, and passed the Chromium golden at mean
error 0.46 and 1.41% bad pixels. The manifest matrix also passed for legacy Metal, headless,
Android, and Vulkan opt-in.

A separate tvOS client of the rollout preview resolved the same pin and launched without a
renderer flag or checkout override. Its startup assertion confirmed SAGAMetal, the Apple TV
Simulator presented the 3D shadow scene, and the SAGA log reported no device errors. The pinned
Web export also passed its golden after the queue failure-path change.

The standalone macOS Studio build used the rollout preview and the pinned AdaMCP revision
from a sibling checkout. SwiftPM rejects a remote AdaMCP that refers to the local AdaEngine
package. The first built app could not load the bundled Lore library because the staged
SwiftPM executable still searched the build directory. Both macOS Xcode targets now
relocate that path to the app's Frameworks directory. The standalone build passed strict
code-signing verification, its packaged CLI returned its version, and its window displayed
the Shader Graph project. SAGA logged the UI, text and sprite pipelines with the renderer
override unset.

The packaged CLI also reproduced a crash before the native player build. Scene conversion
decoded textured components before a render device existed. The exporter now initializes a
headless render device when invoked without Studio's render world. A second issue in the
rollout preview suppressed SAGAMetal in native exports because the exporter disables Swan.
The manifest now treats disabling Swan independently from headless CI. The packaged CLI
exported the Shader Graph sprite fixture with the bundled SDK. The player resolved the
pinned SAGA revision through the local mirror, launched without a renderer override, and
presented the textured sprite through SAGAMetal.

The packaged Studio also exported the same project to Web from its bundled SDK under
`Ada Studio.app`. The export plugin now passes decoded filesystem paths to build tools and
finds SAGA in the game's resolved transitive dependencies. The WASI build uses Swift
Collections 1.4.1 with Swift 6.3.2 to avoid a runtime ABI trap. Debug game exports use
AdaWebPlayer's 4 MiB stack budget. The Chromium WebGPU smoke passed with the pinned SAGA
host assets, 1,924 orange sprite pixels in both captured frames, and frame submission
continuing after a viewport resize. Chromium reported an unreachable-code shader warning.
The CLI's default Release export also launched in Chromium. It presented the textured
sprite before and after resizing, with SAGA's frame counter advancing from 4 to 12.
Both exported JavaScript host assets match the pinned checkout byte for byte.
The Apple workflow preview adds a `studio-web` job that builds standalone Studio and
exports the Shader Graph fixture through its packaged CLI. The browser check verifies
sprite pixels before and after a change to the SAGA surface size. It passed locally on
both Debug and Release exports. The existing AdaWebPlayer golden also passed with
mean error 0.46 and 1.41% bad pixels.

The candidate is published on `AdaEngine/SAGA` at `codex/adaengine-metal-web`. The local tooling test suite reported
one existing macOS installation fixture error when copying system file flags; the same test
fails on the unchanged tooling. The WASM doctor check for the pinned dependency passed.
