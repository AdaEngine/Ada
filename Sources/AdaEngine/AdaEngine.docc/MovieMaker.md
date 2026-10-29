# Movie Maker

Record game footage at a fixed frame rate for trailers and editing.

## Overview

``MovieMaker`` runs a fresh offscreen game world. It advances simulation by exactly
`1 / framesPerSecond`, waits for all camera GPU work, reads the image, and saves it
before starting the next frame. A slow render or disk never skips a movie frame.
The output resolution is independent of the desktop window and display scale.
Capture uses the configured Metal or WebGPU renderer; the non-rendering headless
backend cannot produce movie pixels.

This follows [Godot's Movie Maker workflow](https://docs.godotengine.org/en/stable/tutorials/animation/creating_movies.html):
lossless PNG frames and a synchronized WAV, ready for a video editor or FFmpeg.
No external encoder is required to record. MP4 encoding is a separate export step.

## Record a take

Reuse your gameplay plugins and authored cameras. The recorder supplies the main
scheduler, event delivery, an offscreen render world marker, and a primary window ID; configure
the rendering and game plugins in `make`. Omit native application and window
plugins. For example, this minimal scene records two seconds at 60 FPS:

```swift
import AdaEngine

let maker = MovieMaker()
let configuration = MovieRecordingConfiguration(
    outputURL: URL(fileURLWithPath: "Movies/trailer.png"),
    framesPerSecond: 60,
    width: 1920,
    height: 1080,
    frameCount: 120
)
let take = try await maker.record(configuration: configuration, make: { app in
    app.addPlugin(TransformPlugin())
        .addPlugin(RenderWorldPlugin())
        .addPlugin(CameraPlugin())
        .addPlugin(Core2DPlugin())
        .addPlugin(AudioPlugin())
    app.spawn("Camera", bundle: Camera2D())
    // Install your gameplay, sprite, animation, physics, and scene plugins here.
}, update: { world, frame in
    // Script camera movement or feed input before this simulation frame.
    // frame.index starts at 0; frame.time is movie time in seconds.
}, progress: { savedFrames in
    print("Saved \(savedFrames) frames")
})
```

Use `PerspectiveCameraBundle` and `Core3DPlugin` for a 3D scene. Active cameras
are retargeted after simulation, including cameras created at startup or replaced
by a camera cut. Their projection and world transform are preserved. The game
scene is recorded; host editor controls and desktop windows are excluded.
Game UI must render through the scene's camera pipeline to appear in the take.

`make` runs before plugins are built; load GPU assets after renderer setup, for
example in your game's startup systems or in an awaited setup in `update`.
Assets loaded for a take belong to its app-world asset scope. Load audio resources
inside the recording task so they use the recording's mixer.

## Files and sound

For `Movies/trailer.png`, recording creates:

- `trailer00000000.png`, `trailer00000001.png`, and subsequent lossless frames.
- `trailer.wav`: 48 kHz, stereo, 16-bit PCM, when `includesAudio` is true.
- `trailer.movie.json`: resolution, FPS, actual saved frame count, filenames, and status.

Audio comes from the game's offline mixer, including spatial audio and master
gain. Each video frame pulls exactly `48000 / FPS` audio samples per channel.
FPS must divide 48000; common rates include 24, 25, 30, 48, 50, 60, 120 and 240.
The mixer is scoped to the recording task and does not replace the host's server.
Recording does not use microphone capture or a playback device.

Existing takes are rejected instead of overwritten. Choose a new output name for
each take. Memory is bounded to one frame and one audio block. WAV takes exceeding
the RIFF 4 GiB limit are rejected before recording; split these into shorter takes.

Call `maker.stop()` to finish after the current saved frame. Cancelling the task
throws `CancellationError`; completed frames and a finalized partial WAV remain,
and the manifest records `cancelled`. Other failures record `failed` and rethrow
the original error. The WAV header is updated after every saved frame.

## Warmup and repeatability

`warmupFrameCount` renders and advances the mixer before frame zero without saving
the output. Warmup frames have negative `MovieFrame.index` and `MovieFrame.time`.
Use warmup for temporal rendering effects and intentional preroll. Await asset
loading explicitly; a fixed frame count cannot guarantee that an asynchronous load
has finished.

The fixed clock reaches nested schedulers, physics, animation, and shader graph
time. Explicit physics steps keep their own rate. Random seeds, network input,
wall-clock reads, and asynchronous game code still need deterministic inputs for
repeatable takes. The recorder does not replace those sources of nondeterminism.

## Command line and runnable example

``MovieRecordingConfiguration/commandLine(_:relativeTo:)`` reads Godot-style flags.
It returns `nil` when `--write-movie` is absent, so a game's entry point can choose
between its normal launch and a recording. Parsing alone does not change app startup;
pass the configuration to `MovieMaker.record` with your game's setup.

Run the included animated sprite and audio example from the engine root:

```sh
swift run MovieMakerDemo --write-movie Movies/demo.png --fixed-fps 60 --resolution 1280x720 --quit-after 180
```

Additional flags are `--movie-warmup N` and `--movie-no-audio`. `--quit-after N`
counts saved frames, excluding warmup. Relative paths resolve against the directory
passed to `commandLine`, which defaults to the working directory. Without capture
flags, the demo records 180 frames at 640×360 in `Movies/demo.png`.

Convert a take to MP4 using the same FPS as recording:

```sh
ffmpeg -framerate 60 -start_number 0 -i Movies/demo%08d.png -i Movies/demo.wav -c:v libx264 -crf 15 -pix_fmt yuv420p -c:a aac -shortest Movies/demo.mp4
```

For a take without audio, omit `-i Movies/demo.wav` and `-c:a aac`. For transparent
footage, set a transparent camera background and use a video format that supports
alpha; H.264 MP4 does not preserve it.

## Validate recording

`swift test --filter MovieMaker` checks configuration, image and WAV writing,
failure metadata, and the simulation clock. GPU cases use the same serialized
`Render3DGPUTests` parent as the engine's other rendering tests.

On macOS, run `ADAENGINE_GOLDEN_METAL=1 swift test --filter MovieMaker`. For native
Windows WebGPU validation in PowerShell:

```powershell
$env:ADAENGINE_GOLDEN_WEBGPU = "1"
swift test --filter MovieMaker
```

These cases record real camera pixels and a camera cut, game audio, warmup,
graceful stopping, task cancellation, and low-FPS physics advancement.
