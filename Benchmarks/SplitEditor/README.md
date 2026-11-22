# Split editor resize benchmark

Orbit Workspace is a native AdaUI benchmark for dragging the divider between an editable Swift document and a project file panel. The built-in fixture contains four virtual files. Clicking a file opens it. Edits stay in memory for that launch. The code editor uses line numbers, lightweight syntax coloring, and soft wrapping.

## Launch

From the engine root, use macOS 26 and the engine's Swift 6.3.2 toolchain.

```sh
bash Benchmarks/SplitEditor/build.sh
open ".build-tools/split-editor/Orbit Workspace.app"
```

Drag the mint divider in either direction. Both panels resize, and long code lines reflow as the editor gets narrower. The window requests display-linked updates up to 120 Hz, subject to the display's capabilities.

## Measure the divider

Give the launching terminal macOS Accessibility and Screen Recording access. Close the demo window before running the probe so it can launch an isolated instance. Leave the pointer alone until the probe exits.

```sh
out="$PWD/.build-tools/split-editor"
swiftc -O -parse-as-library Benchmarks/SplitEditor/MeasureResize.swift -o "$out/measure"
"$out/measure" "$out/Orbit Workspace.app" "$out/with-wrap"
ORBIT_SOFT_WRAP=0 "$out/measure" "$out/Orbit Workspace.app" "$out/without-wrap"
```

The probe posts 288 drag events over 2.4 seconds and tracks the divider's x-coordinate in ScreenCaptureKit. It checks both the leftward excursion and the final position before writing the input timeline, changed positions and screenshots. The output includes the display's reported maximum refresh rate, change cadence, p95 between captured position changes, and app process CPU during the capture and final 100 ms. At 120 Hz, a single refresh interval is 8.33 ms.
