# Windows Studio rendering implementation and validation

The [approved design](../Designs/windows-studio-rendering.md) covers Windows frame pacing and the Direct3D 12 rollout. The acceptance target is 60–120 displayed FPS up to the monitor refresh rate. Report 16.67 ms and 8.33 ms as the respective frame budgets, alongside the measured p95 and p99 in each workload.

## Vulkan performance

1. Use a real Vulkan device to count submissions for adjacent writes, then read back overlapping writes and verify that a readback between writes sees the earlier contents. Enable the existing ordered batching path and compare native submission counts.
2. Attribute repeated allocations by buffer label and call site. Reuse the existing buffer policies where resource ownership and work retirement allow it. Check the production viewport and AdaUI draw paths with the same input sequence and visual output.
3. Capture Windows Release PresentMon runs for camera orbit, code scroll, and split-pane resize. Keep tracing off for the timed run. Use separate profiling runs to choose subsequent draw encoding, pacing, or scene work.

## Direct3D 12

1. Extend SAGA in a worktree based on AdaEngine's pinned revision. Exercise multiple window surfaces including retirement and resize on an actual D3D12 device. Compare multiple color attachments and depth-only draws by readback. Run the compiler and backend suites on Windows with DXC available.
2. Connect the shared AdaRender resource and command bridge to the native runtime. Validate shaders and DXC packaging and run the Studio and player entry points with an explicit backend. Run golden frames on the matching hardware and check Vulkan selection, startup fallback and capability reporting.
3. Switch the Windows default after the approved compatibility, hardware and performance checks pass. Publish the selection and measurement instructions through the [Windows performance guide](../../Editor/Documentation/WindowsPerformance.md) and its existing [Editor README link](../../Editor/README.md). Exercise the documented commands against the staged release distribution.

Run the focused checks for each slice, the shared contribution validation and independent review. Keep PresentMon captures and runtime logs under `.build-tools/windows-studio-frametime`.
