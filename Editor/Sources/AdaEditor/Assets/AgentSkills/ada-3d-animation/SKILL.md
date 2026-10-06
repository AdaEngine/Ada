---
name: ada-3d-animation
description: Inspect imported skeletal clips and skins, configure Model3DSource playback and diagnose animation compatibility in Ada Studio.
allowed-tools: editor.model.inspect, editor.model.validate, editor.components.describe, editor.scene.get, editor.scene.apply, editor.play.start, editor.docs.read
---

# Ada Studio Imported Animation

1. Inspect the GLB/glTF for skins, joint counts, exact case-sensitive clip names, durations and interpolation modes. Unnamed clips use `Animation <index>`. Use the returned name without inventing Idle/Walk/Run names.
2. Read the current `Model3DSource` component descriptor. For simple playback set `animation`, `autoplay: true` and `repeats` on the authored entity, retaining its source and other fields. Each placed model has an independent runtime player.
If the scene payload already contains `animationGraph`, it takes precedence over the single `animation` clip. Preserve the authored graph; do not silently remove it to force clip playback. Pose-graph editing and skeletal keyframe/rig authoring are different capabilities.

3. Validate before Play. The native importer supports node TRS translation/rotation/scale channels with LINEAR, STEP and CUBICSPLINE interpolation; this profile rejects morph-weight animation and extra joint influence sets. Each skin supports at most 128 joints.
4. Run visible Play, inspect runtime errors, and compare completed captures at different times. A clip existing in the file is not proof it plays. The isolated logic simulation does not install the Model3D plugin and cannot verify skeletal playback.

For a frozen pose, check the selected name, autoplay, Play state and missing model/clip errors. For deformation, investigate joint order, inverse bind matrices, rest transforms and vertex weights. Imported asset bounds reported by inspection are rest-pose bounds, not animated bounds. Do not decimate a character as a static prop or discard its skeleton to solve a rendering issue.

Studio tools do not author skeletons, retarget rigs or create skeletal clips. Use an external authoring pipeline and reimport its validated GLB; report that boundary explicitly.
