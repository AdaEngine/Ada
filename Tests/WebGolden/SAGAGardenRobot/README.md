# GardenRobot browser smoke

This standalone Swift app runs GardenRobot through idle, walk, run, jump, fall, and landing
with the engine's character controller and skeletal animation. The scene starts its demo after
its first completed render and repeats, reversing direction after each cycle.

From the AdaEngine root, use the Swift toolchain and WASM SDK described in
[Tooling.md](../../../Documentation/Tooling.md). On Windows, run the export from WSL.
The commands stage the sample with the existing GardenRobot fixture in a scratch package.

```sh
repo="$PWD"
demo="$(mktemp -d)"
cp Tests/WebGolden/SAGAGardenRobot/{Package.swift,GardenRobot.swift} "$demo/"
cp Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb "$demo/"
cp Package.resolved "$demo/"
(
  cd "$demo"
  export ADAENGINE_GARDEN_ENGINE_PATH="$repo" ADAENGINE_WEB_EXPORT=1 BUILD_WASM=1
  swift package --allow-writing-to-package-directory --allow-network-connections all \
    export-web --product GardenRobot --release --output "$demo/web"
)
python3 ada_tool.py serve wasm --directory "$demo/web" --port 8080
```

Open `http://127.0.0.1:8080` in Chrome with WebGPU. The page loads the browser renderer before
showing the scene. Leave `?sagadebug` off when judging playback speed.

The smoke test serves the exported bundle, follows the six phases, and checks actual Chrome
screenshots for visible GardenRobot pixels and changes in pose. Run it from the AdaEngine root
with `playwright-core` installed or set `SAGA_PLAYWRIGHT` to its installed directory.
Set `SAGA_CHROMIUM` to a Chrome executable if needed and `GARDEN_ROBOT_SCREENSHOTS` to save the
shots.

```sh
GARDEN_ROBOT_BUNDLE="$demo/web" node --test Tests/WebGolden/SAGAGardenRobot/Presentation.test.mjs
```
