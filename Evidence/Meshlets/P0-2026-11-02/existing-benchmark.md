Scene: 400 PBR spheres (8 materials), ground, sun with 3 cascades, 6 point and 2 spot lights, 1920x1080, 90 measured frames, best of 3 rounds.
WebGPU has no per-pass GPU timestamps here. `wall` and `free` are CPU + GPU frame wall time; `free` includes a final readback. The GPU pass/sum columns are unavailable.

| configuration |  | sum | wall | free |
| --- |  | ---: | ---: | ---: |
| bare |  | - | 66.74 | 5.25 |