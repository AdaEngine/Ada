# Game diagnostics overlay

See the game's update rate while you play. The overlay shows **FPS** and
**Frame time** in the top-left corner of the game window. Mouse and keyboard
input still reach the game under the overlay.

## Enable it in Ada Studio

1. Open the build-target picker and choose **Edit Build Targets…**.
2. Select a target with a local desktop **Run Destination**, then turn on
   **Diagnostics overlay** and select **Save Build Targets**.
3. Run the selected target. The first readings appear after about one second.

For example, duplicate the **Main** target, call the copy **Performance**, and
enable the overlay only for that copy. Run **Performance** to inspect frame
pacing, then select and run **Main** to play without the readout.

The setting applies to local product runs on Windows, macOS, and Linux for
AdaScript games and compatible Swift apps. It works in both Debug and Release.
It is off by default and applies on the next run. Scene-document Play, debugger
sessions, AdaPlayer, exports, and Movie Maker run independently of this setting.

## Enable it from a shell

For a Swift app using `DefaultAppWindow` or `WindowGroup`, set the environment
variable when you launch the product. The app must be built with an AdaEngine
version that includes the overlay.

```bash
ADAENGINE_DIAGNOSTICS_OVERLAY=1 swift run -c release
```

```powershell
$env:ADAENGINE_DIAGNOSTICS_OVERLAY = '1'
swift run -c release
Remove-Item Env:ADAENGINE_DIAGNOSTICS_OVERLAY
```

## Read the numbers

**FPS** is the number of game update intervals per second. **Frame time** is the
average duration of those intervals in milliseconds. At a steady 60 FPS, it
reads about 16.7 ms. Both numbers include frame pacing and stalls between
updates. They describe the game's update loop. Use profiling tools to measure
GPU work or investigate individual slow systems.

The overlay refreshes its text about once per second. It displays dashes while
collecting the first sample window and after an explicit simulation pause.
