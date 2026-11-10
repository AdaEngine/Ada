# Game diagnostics overlay implementation plan

[Approved design](../Designs/game-diagnostics-overlay.md)

1. Exercise the project model and SwiftPM command builder with a temporary
   project containing two targets. Add backward-compatible decoding and target
   draft behavior, then scope the Swift launch environment to local product Run.
2. Implement an isolated frame cadence sampler and shared AdaUI readout. Mount
   it above standard Swift app content and the AdaScript product Run content.
   Check sampling, input routing, session lifetime, and pause behavior.
3. Wire the localized target setting to the existing draft and launch
   destination. Exercise the mounted settings control in both languages.
4. Add the AdaEngine DocC article and topic entry. Update Studio's Build & Export
   guide and regenerate its offline copy. Verify the two-target Studio walkthrough
   and the Swift environment example.
5. Run focused Swift Testing suites in both packages and the complete contribution
   profile. Capture runtime evidence for local AdaScript and Swift Run on Windows
   WebGPU, macOS Metal, and Linux Vulkan. Include UI under the readout, input
   pass-through, resize, hot reload, and Run/Stop. Use the native package tests
   and platform runners where available, and report unavailable checks.
6. Submit the final scoped changes and validation logs for independent review.
   Resolve findings, rerun affected checks, and verify the Done gate.
