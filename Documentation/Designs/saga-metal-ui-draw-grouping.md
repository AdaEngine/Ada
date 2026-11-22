# Group compatible UI draws on SAGA Metal

Status: approved.

## Problem

AdaUI's `UIRenderNode` opens a single color pass for ordinary window UI and changes the scissor and render state between draws. The AdaRender SAGA adapter currently emits one legacy SAGA render command per draw. SAGA's Metal backend opens a native render encoder for each command. For indexed draws with per-vertex input, it also opens a compute encoder to check index bounds and prepares separate indirect draw arguments.

In the macOS SocialFeed Time Profiler capture, command encoding accounted for 311 ms of sampled CPU over seven scroll cycles. Stacks under `MetalDevice.renderEncoder` and `MetalIndexValidator.encode` accounted for 103 and 101 ms respectively. The final measured CPU gap against GPUI was 7.3× in the preceding Release series. The goal of this change is to test how much of that gap the repeated encoders contribute.

Paging the indirect arguments within each command buffer reduced median CPU from 928 to 883 ms in a six-pair Release series. Five pairs favored shared pages. A repeat had medians of 942 and 917 ms, with only two pairs favoring shared pages. The experiment reduced temporary buffer allocations while both encoder calls still ran per draw.

After the isolated buffer upload improvements, a matched three-scroll Time Profiler capture sampled 309 ms under SAGA submission. The Metal backend accounted for 211 ms of those samples, including 126 ms in command encoding. The driver submit stack outside SAGA accounted for another 150 ms. In a separate six-pair Release comparison without Instruments, the current engine with the local SAGA changes used 0.888 s of CPU per scroll, compared with 0.123 s for GPUI.

A diagnostic census of three matched SocialFeed scrolls captured 2,282 enabled legacy indexed draws per run. Each called the Metal index validator. A conservative check for adjacent draws on the same single-sampled color subresource, with load/store and read-only bindings, found 60 runs with a median length of 37 draws. In that subset, one render encoder and one validation encoder per compatible run would replace 2,282 of each with 60 of each, while keeping all 2,282 draws and index checks. Measure actual CPU and visible frame delivery after implementing the grouped path.

## Design

Group consecutive compatible draws inside the existing SAGA Metal command list. Keep draw order and the AdaRender API. Use a conservative eligibility check for an initial path that covers the ordinary indexed UI pass.

- A group uses one single-sampled color subresource with no resolve, depth, stencil, multiview, rate map, or query attachment. Its draws use the same target. The first draw applies its recorded load action, subsequent draws load the group's contents, and the final result stores. A clear or other incompatible attachment action starts a separate group or takes the existing path.
- Group draws whose shader resource declarations and bindings establish read-only input. Require sampled textures and views with distinct backing storage from the render target. Intervening commands, unsupported bindings, and attachments with visible intermediate effects break the group. Route those sequences and other backends through the existing implementation.
- Prepare required texture initialization and index checks before opening the group's render encoder. Encode the checks for eligible indexed draws together. The compute operations retain their per-draw index ranges, index types, base vertices, primitive restart policy, and vertex capacity checks. Each indirect draw reads its own arguments. Retain the associated buffers through native command buffer retirement.
- Apply each draw's pipeline, bindings, viewport, scissor, and blend state in order. Clear or reset dynamic state when the next draw's state calls for defaults. Preserve empty-scissor handling, texture initialization, and the behavior of a clear-only command.

The Metal backend owns eligibility and grouping. Apply grouping after AdaUI has scheduled extraction and presentation and encoded its pass boundaries around glass captures. This is internal performance work using the existing public command API and guide.

An alternative is to encode the entire AdaRender pass as a new cross-platform SAGA command type. The narrow Metal path can test the encoder cost first with the existing command representation. Evaluate whether a richer command type is worthwhile once the measured contribution and the coverage of the compatible subset are known.

## Verification

- Test the actual Metal submission path with multiple compatible indexed draws. Verify native encoder counts separately from timed runs. Compare readback of overlapping translucent draws, different scissor and viewport states, mixed index widths, valid and invalid indices, and multiple indirect arguments in one group.
- Exercise boundaries with an intervening copy, a clear, and an incompatible binding or attachment. Confirm each condition takes the required execution path and preserves output. Use Metal API Validation on the native tests.
- Run at least six interleaved Release SocialFeed samples per variant at the same viewport and confirm scroll endpoints. Compare process CPU and record render and compute encoder counts in diagnostic runs. Record presentation data when the host exposes app-attributed timestamps.
- Check the ordinary game camera and mixed camera tests. Record which GPU configurations were exercised and obtain independent review before landing.
