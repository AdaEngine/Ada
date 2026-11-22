# Reuse transient AdaUI geometry buffers

Status: approved.

## Problem

On the macOS SocialFeed benchmark, the first SAGA change lowered median process CPU from 1,444 to 1,352 ms for the same 1.9-second scroll. GPUI used 109 ms. A separate run with queue logging counted 3,379 buffer creations, 3,424 uploads, 3,353 buffer destructions, and 47 presentation requests during one matched scroll. In a second diagnostic run with allocation labels and matching scroll endpoints, glyph buffers accounted for 2,302 creations and quad buffers for 608 out of 2,953 total creations. Those counts include the entire render world and are used to locate churn. Use the uninstrumented runs for CPU comparisons.

AdaUI writes buffers in `UIRenderTesselationSystem.flushStateIfNeeded`. Each flush produces a new `UIDrawData` slice with fresh `BufferData` instances. The existing geometric capacity growth only applies when an instance survives subsequent writes. Scrolling can rebuild the same clips and draw slices every frame.

Discarding draw slices with empty scissor rectangles is an independent fix. With the SAGA upload change in both builds, this reduced median process CPU from 1,348 to 1,196 ms across six matching scrolls. In two diagnostic runs with 58 presentation requests each, buffer creations went from 4,212 to 3,208. The remaining allocations are the reuse proposal's baseline.

## Design

Keep a pool of fully overwritten, transient UI geometry buffers in the render world that creates them. Start with vertex and index buffers from rebuilt draw slices. Keep the public `BufferData` and `UIDrawData` APIs and the existing rendering order. Keep persistent `UILayerDrawCache` entries and non-UI rendering on their current paths in the initial patch.

Reuse a buffer only for the same rendering device and compatible usage, with enough byte capacity for the complete upload. Keep element and batch counts on the current draw slice. Spare capacity must never extend a draw or upload. Grow when required and retain a bounded set of freed buffers so a temporarily large window cannot establish an unbounded high-water mark.

The pool must respect both CPU ownership and GPU completion. A draw slice retains its buffers while a render list may draw it again, including partial rebuilds where another window's list remains live. Retain each submitted lease through the owning command buffer's completion callback. Return the buffer to the pool only after its final draw-list owner and its final outstanding submission have released it. Allow release after encoding failure or device teardown through the normal resource lifetime. On a backend where the completion contract cannot establish safe reuse, keep the existing allocation path.

Use the current extraction and render schedule. Leave input, animation, game simulation, surface acquisition, submission order, draw order, clipping, and presentation pacing under the existing policies. Start by reusing allocations at the existing upload points. Batching uploads and changing the pass graph are separate changes with different ordering requirements.

This is an internal performance improvement. Public usage and platform requirements do not change, so the initial scope has no user-guide change. Independent review must confirm that scope.

## Verification

- Count allocations by buffer label before and after the change, and account for the number of frames in each diagnostic capture.
- Exercise real draw-list rebuilds and submissions across successive frames. Verify that an in-flight buffer and a buffer held by another window's current draw list cannot be reused. Cover allocation growth, partial rebuilds, cached layers, clip transitions, and device or window teardown.
- Compare the same SocialFeed Release workload across six alternating pairs at the same viewport. Verify visible post IDs and screenshot geometry before interpreting CPU. Collect allocation and upload counts in separate diagnostic runs. Capture AdaUI frame delivery across the same scroll to check that the CPU difference does not come from drawing fewer frames.
- Run focused AdaUI and AdaRender tests, native Metal rendering checks, and independent review. Record any backend validation that cannot run locally.
