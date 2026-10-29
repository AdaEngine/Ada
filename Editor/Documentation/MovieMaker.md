# Movie Maker in Ada Studio

The desktop toolbar's red **Movie Maker** button opens capture settings. Choose
**Project** to record the AdaScript project's startup scene and systems, or
**Current Scene** to record the active scene through the editor's Scene Play path.
Swift projects can record Scene Play; the Project option does not launch or capture
an external Swift executable.

Set FPS, width, height, duration in seconds, the `.png` output path, and whether to
include game audio. Resolution shortcuts select 720p, 1080p or 4K; custom dimensions
remain editable. FPS must divide the 48 kHz audio rate, for example 24, 30 or 60.
Fractional durations round up to a whole frame.

Paths can be absolute or relative to the project folder. **Choose Folder…** opens
the system folder picker and preserves the file name. Settings are saved per
project in `.ada/workspace/movie-maker.json`. They are not game runtime settings
and are not needed by exported games.

**Start Recording** saves open documents, prepares the project's runtime, loads
scene/model assets before frame zero, and runs the engine's fixed-step Movie Maker.
It records the authored game cameras without editor panels or gizmos. A UI overlay
drawn outside the camera's render pipeline is not included. Asynchronous game code,
network input and random seeds retain the same repeatability requirements as the
[engine API](../../Sources/AdaEngine/AdaEngine.docc/MovieMaker.md).

The dialog shows saved-frame progress and **Stop Recording**. The toolbar button
also becomes Stop with a progress percentage. Closing the settings dialog leaves
the recording running. The ordinary Run controls are disabled during capture;
the ordinary Stop button also finishes the movie. Closing the workspace cancels
the take and preserves completed frames and finalized partial audio.

For `Movies/clip.png`, the output is `clip00000000.png`, subsequent numbered frames,
`clip.wav` when audio is enabled, and `clip.movie.json` with the actual frame count
and completion status. Existing takes are rejected with an explanation; choose a
new name for another take. **Show Movie Files** opens the output folder.

PNG/WAV recording requires no external encoder. To assemble an MP4 at the same FPS:

```sh
ffmpeg -framerate 60 -start_number 0 -i Movies/clip%08d.png -i Movies/clip.wav -c:v libx264 -crf 15 -pix_fmt yuv420p -c:a aac -shortest Movies/clip.mp4
```

The shared controls are localized in English and Russian. Focused tests cover
real project-local persistence, validation, toolbar clicks, mounted text editing,
resolution presets and language changes. GPU integration is opt-in:

```powershell
$env:ADAEDITOR_MOVIE_GPU = "1"
swift test --package-path Editor --filter EditorMovieMakerGPUTests
```

Use the Windows dependency overrides documented in `AGENTS.md` for native Windows
builds and tests. This test uses real project/scene files, the production editor
recording command, the game renderer, and the offline audio mixer.
