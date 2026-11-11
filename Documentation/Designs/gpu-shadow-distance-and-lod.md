# GPU distance culling and LOD for directional shadows

This internal rendering improvement extends [GPU-driven shadow batching](gpu-driven-shadow-batching.md) and [incremental mesh extraction and cascades](incremental-mesh-extraction-and-cascades.md). The existing GPU shadow registry excludes sources with LOD alternatives or a finite draw distance. Those sources are common in the standalone city, where moving the camera requires preparing CPU caster lists for all directional cascades.

## Behavior and ownership

- Extend directional WebGPU shadow batching to handle finite draw distance and fade first. Use the main camera's distance metric and settings for every cascade. Preserve the cascade frustum test, per-instance bounds, forced visibility, and the shadow material's existing fade behavior.
- Add GPU selection among supported static mesh LODs. Pool geometry for the supported levels and select one level per placement using the main camera's projection and the same thresholds and hysteresis as CPU preparation. A level can contain multiple parts. Each cascade consumes the same selection and applies its own frustum test.
- Keep selection history per camera and stable caster identity. Reset or reconcile history when the matching source or camera changes. Protect buffers still in flight and retain a complete CPU fallback if a source, device limit, backend, or view cannot preserve the contract. Route unsupported material, animated geometry, and local shadow views through their current paths.
- AdaCorePipelines owns eligibility, geometry groups, and per-camera state. AdaRender owns the WebGPU compute input and indirect output. Use the existing indirect draw path and account for its buffer sizes and device limits. If replicating full LOD geometry for the first implementation outweighs the measured CPU savings, keep the verified distance path independently deployable and report the LOD result.

## Acceptance

- Compare GPU and CPU shadow output with fixed and moving cameras, distance/fade and LOD transitions, frustum/distance/LOD settings changes, caster removal, and multiple cameras. Exercise capability fallback and frames in flight. Run focused WebGPU shader and rendered tests using the existing validation script.
- Alternate baseline and candidate on the same Windows machine using the standalone sunset city. Measure fixed and orbiting views at verified 1920×1080 with the same seed, traffic, geometry, shadow and LOD settings. Record mean and p95 frame time, directional shadow preparation CPU time, counts by path, and upload or buffer costs. Judge the change against run-to-run variation.
- Keep the existing scene authoring and configuration contract. This internal change requires no user article or navigation update. The standalone city run supplies example evidence, and the contributor runner checks the design and performance record.
