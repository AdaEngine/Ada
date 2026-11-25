# Windows Studio frame pacing and Direct3D 12

Status: Approved in the project conversation on 2026-11-23.

## Current behavior

Ada Studio on Windows presents through SAGA Vulkan and a Win32 swapchain. The original SAGA rollout chose Vulkan first so Windows and Linux could share a backend. AdaEngine later enabled that backend for Android as well. SAGA now also has a Direct3D 12 backend built on DXGI, HLSL and DXIL. AdaEngine's Windows manifest and render entry point currently select `SAGAVulkan` and SPIR-V.

On the Windows x64 Release build at AdaEngine `4ed2f79cb`, rotating the editor camera in Skeletal Garden at a 2560 × 1392 logical window measured 11.97 displayed FPS, 138.91 ms p95 display interval, and 159.74 ms p99 over 169 intervals. PresentMon reported 28.79 ms mean GPU busy time. The measurements reproduce an interactive slowdown. The GPU time leaves substantial room to investigate CPU encoding, submission and queue waits, and the GPU workload itself also exceeds the budget for 60 FPS in this run.

AdaEngine currently batches adjacent buffer writes for Metal and browser WebGPU. Vulkan can record several uploads in one submission but the Windows adapter sends these writes individually. A separate 10-second queue trace during the same orbit counted 16,807 individual buffer-upload jobs, 13,310 buffer-creation jobs, and 73 presentation jobs. Adjacent grouping alone would reduce the observed upload sequence to 7,044 jobs with a 64-write cap, before accounting for worker timing. These are diagnostic counts, with logging enabled. AdaUI's compatible indexed draw grouping also currently targets Metal. The Vulkan window can queue presentations asynchronously, and the Windows loop uses a timer for SAGA. Queue depth, frame coalescing and monitor cadence need their own evidence before a pacing change.

## Windows performance

Ship measured fixes on the current Windows renderer as soon as they are independently useful. Record per-frame upload counts, buffer creation counts and labels, render and validation pass counts, frames outstanding, and CPU and GPU timings in diagnostic runs. Use timed runs without diagnostics to compare user-visible performance.

- Batch consecutive Vulkan buffer uploads where measured. Preserve write order, snapshot bytes at enqueue time, and stop the batch at command, resource lifetime or readback boundaries. Verify repeated overlapping writes and reads between uploads with actual device readback. Trace the code allocating buffers repeatedly, and reuse allocations where their ownership and GPU retirement allow it.
- If per-draw command encoding is material, reuse compatible draw grouping for ordinary AdaUI passes. Preserve attachment operations, draw order, clipping, blending, index validation and resource retirement. Use a small testable slice before extending to scene passes.
- If presentation waits or queued frames dominate, bound latency per visible surface, preserve the latest requested frame during backpressure, and exercise resize, minimize, restore and multiple windows. Keep render-on-demand behavior for idle windows and verify a window moved between monitors of different refresh rates.
- Profile the expensive 3D passes separately from UI. Preserve authored visual quality in matched comparisons. Record any rendering tradeoff as a separate design decision.

## Direct3D 12

Bring up SAGA Direct3D 12 as an explicit Windows development option. Once it passes the default-switch criteria below, make it the preferred backend in Windows Studio and native Windows players. Retain Vulkan as an explicit choice and a startup fallback when Direct3D 12 or its required capabilities are unavailable. Record the selected backend, adapter and fallback reason in startup diagnostics. A forced backend must report its initialization failure. Keep the backend fixed for the lifetime of the renderer so resources stay on their creating device.

SAGA owns Direct3D 12 resources, command recording and DXGI presentation. Add the support Studio requires on one device, including multiple Win32 surfaces, resize and retirement, multiple render targets, depth-only passes, texture copies and readback, and the required compute and indexed draw paths. At the current SAGA pin, `D3D12Backend.makeDevice` accepts one optional window handle and the draw path rejects additional color attachments. AdaEngine's main 3D pass uses multiple outputs. Preserve verified DLSS and ray-query behavior on Windows before switching the default for configurations that use them.

AdaRender keeps its public rendering API and uses the shared SAGA queue and resource adapters. Compile the existing WESL/WGSL shaders through SAGA's HLSL path, then DXC. Pin and package the required DXC libraries and notices in the Windows Studio and player distributions. Test launch on a clean Windows environment with the shipped files. Linux and Android continue to use Vulkan, Apple uses Metal, and the browser uses WebGPU.

## Acceptance

- Compare the same Windows Release workload, GPU, monitor, viewport, initial camera, and input trace across variants. Measure a code-editor scroll, a split-pane drag, and a 3D viewport orbit. Warm shaders and assets before measuring. Run at least three paired samples per workload and retain PresentMon captures with displayed FPS, p50, p95, p99, missed display intervals, and GPU busy time. Retain diagnostic captures separately.
- Require an improvement in the reproduced bottleneck and lower p95 and p99 in the affected workload. Verify no repeatable slowdown in the other matched workloads. Use 16.67 ms as the frame budget at 60 Hz and report where the measured GPU cost alone exceeds it.
- Before making Direct3D 12 the default, pass comparable 2D, AdaUI and 3D golden-frame and readback checks, including shadows and post-processing, with the existing tolerances. Open and resize multiple real Studio windows, run a native player, and explicitly exercise both backend selection and fallback. Check a discrete GPU and an integrated GPU. Compare Direct3D 12 and Vulkan on the same adapter and confirm that the new default meets the pacing and visual checks. Follow contribution validation and independent review for each shipped change.

## User documentation

Update [Windows Studio performance](../../Editor/Documentation/WindowsPerformance.md) and its existing [Editor README navigation](../../Editor/README.md). Document how to identify the active backend, run with an explicit backend, interpret startup fallback, and reproduce the PresentMon comparison. Verify the commands with the shipped Studio and player, including a clean Windows installation. Check links and update the offline guide if the documentation generator includes the changed guide.
