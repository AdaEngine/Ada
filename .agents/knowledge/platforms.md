# Platform and Backend Constraints

Read [the existing platform/render/web reference](../skills/adaengine-development/references/platform-render-web.md)
and actual manifest conditions before changing shared code. These notes describe verification boundaries,
not a claim that every platform has been tested in the current task.

| Platform | Engineering and evidence requirements |
| --- | --- |
| macOS and Apple mobile | Keep AppKit/UIKit/Metal APIs conditional. Verify the relevant app/device or simulator path. macOS compilation does not prove iOS, tvOS, or visionOS behavior. |
| Windows | Respect headless/plugin flags and bounded Swift test parallelism in existing CI. SwiftLint is not supplied by the native build plugin. Keep paths, subprocess arguments, DLL/resources, and Git Bash differences explicit. |
| Linux | Inspect native windowing, audio, Swan/Dawn, and system dependencies before launch. A headless build cannot establish interactive window or GPU behavior. |
| Android | Inspect `Tools/Android/`, its tests, current SDK/NDK and packaging scripts. Validate ABI/resources and actual emulator/device lifecycle when behavior depends on them. Host Swift success does not prove APK execution. |
| WASM/browser | Use current export scripts and SDK policy. Verify emitted WASM, JavaScript loader, manifests, and resources over HTTP in a browser. Native WebGPU pixels do not prove a browser export. |
| Metal/WebGPU | Validate shader conversion and actual GPU pixels; keep golden suites serialized. CPU tests, cached WGSL, and disabled golden flags do not establish GPU correctness. |

For browser setup use the repository's `ada_tool.py` and `Documentation/Tooling.md` when available,
plus current plugin sources; do not assume a personally installed WASM skill exists.
Studio WebUI builds may need Cloud panels from the separate adawebsite repository. Missing panels
are a blocker, not a successful frontend build. Do not modify sibling repositories implicitly.

Editor packaging may require staged native bindings, resources, and a complete distribution.
Read `Editor/AGENTS.md`; a bare SwiftPM executable is not proof of the installed Studio experience.
Preserve the shared `.build` and reuse task-owned scratch directories after toolchain mismatch.
Do not replace missing hardware validation with a claim based on another operating system.
