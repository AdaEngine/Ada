# SAGA browser smoke scene

A minimal project for the SAGA browser golden-frame check: a perspective camera with `Environment3D`, a shadow-casting
sun, a floor, two cubes and a sphere. It uses only components the web player supports.

The reference image is
[`GoldenFrames/saga-browser/smoke-160x96.png`](../../AdaEngineTests/GoldenFrames/saga-browser/smoke-160x96.png).

1. Export the web player (see `Documentation/Tooling.md`, "Browser renderer") and pack this project into it:
   `AdaWebPlayerPackager <player-export> Tests/WebGolden/SAGASmoke <bundle>`.
2. Run `node script/web_golden_saga.mjs <bundle>`. It opens `?solo=1`, waits for a settled frame, downsamples
   it to 160x96 and compares it with the reference (per-channel tolerance 12, at most 2% bad pixels, mean error at most 4).
3. After an intended rendering change, review the new frame and re-record with `--record`.

The same helpers are usable from any browser console on the page: `import("./saga-golden.mjs")` exposes
`captureStable`, `checkGolden`, `compareFrames`, `frameToPng` and `frameFromPng`.

To check a Web export of the Studio [Shader Graph fixture](../../../Editor/Tests/Fixtures/ShaderGraphSmoke),
run `node script/web_golden_saga.mjs <export>/web --studio-export --actual=studio-web.png`.
The check reads the orange sprite pixels from SAGA before and after a viewport resize and
verifies that the resized surface presents another frame.
