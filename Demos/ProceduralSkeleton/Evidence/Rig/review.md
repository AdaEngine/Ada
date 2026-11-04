# Native rig and walk review

Reviewed BindPose and Walk phases 0, 6, 12 and 18 after correcting the baked normal
matrix. The shield face and rotated bones now keep the original outward normals
and expected lighting; this is also checked against the original GLB buffers.

The head, jaw, torso, clothing, arms, feet, sword and shield remain attached.
Opposite feet exchange stance/swing, knees bend, and the wrists keep the props
upright as the arms swing. The cycle is an in-place walk on a level plinth.

The preview GIF contains 24 completed native GPU frames of fixed clip phases;
continuous Walk playback was checked separately with changing live joint poses.
There are no script errors in the captured live run. This is prototype animation:
cloth simulation, fingers, locomotion control, uneven terrain and a comprehensive
self-intersection/deformation review are outside this experiment.
