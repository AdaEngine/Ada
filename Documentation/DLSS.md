# DLSS

The user guide is the DocC article `DLSSUpscaling` (`Sources/AdaEngine/AdaEngine.docc/Articles/3D/DLSSUpscaling.md`).
The approved design is [dlss-upscaling](Designs/dlss-upscaling.md).

For contributors: DLSS runs through the NGX bridge in `Tools/NGXBridge` (a C ABI over the NVIDIA SDK, built by
`python ada_tool.py build ngx-bridge`) and SAGA's native Vulkan pass. `SAGADLSS.swift` owns the session and the
Super Resolution and Ray Reconstruction upscaler; `DLSSRuntime` discovers the files; selection and status live in
`TemporalUpscaling.swift` and `TemporalReconstructionStatus.swift`. The GPU checks need an NVIDIA GPU and run when
`ADAENGINE_DLSS=1` (`DLSSSmokeTests`, `Render3DDLSSTests`).
