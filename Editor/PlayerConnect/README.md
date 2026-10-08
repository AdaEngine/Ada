# AdaPlayer preview

AdaPlayer is a separate iPhone/iPad app (`org.adaengine.player`) for running
AdaScript games sent from AdaEditor. The `AdaPlayer-iOS` XcodeGen target stages
the shared executable and selects `AdaPlayerApp` at startup. It uses the same
project builder, scene loader, input mapping, runtime plugins and AdaScript VM
as local Run. This first target still links the editor's dependencies; it does
not start the editor UI, cloud settings, notifications, updates or MCP server.

## Run a game

1. Generate the project with `xcodegen generate` in `Editor/`.
2. Build/install `AdaPlayer-iOS` using an Apple development profile for the
   device. This bundle ID is independent of the installed editor.
3. Open AdaPlayer and allow Local Network access. Keep it in the foreground.
4. Open an AdaScript project in AdaEditor on the same Wi-Fi. Select **AdaPlayer**
   in the Run destination menu, then **Run**.
5. Enter the six-digit code shown on the device and choose **Connect and Run**.
6. Read device logs in the editor output. **Run** sends a fresh snapshot and
   restarts the game; **Stop** returns to the player's connection screen.
   **Disconnect**, closing the editor, or backgrounding the player ends pairing.

For desktop diagnostics the shared executable also accepts `--ada-player`.

## First-version boundaries

- Bonjour (`_adaplayer._tcp`) discovers devices on the local network.
- TCP carries versioned length-prefixed JSON. Pairing is required before deploy
  or stop, has a 15-second deadline, and permits one editor at a time.
- The transport is **not encrypted**. Use this development preview on a trusted
  local network. Do not expose its port to the internet.
- Every deployment contains the metadata, resolved AdaScript sources, assets,
  declared resource folders and startup scene. Git history, build caches and
  the editor's local configuration are not copied. Imported scripts are bundled
  as numbered source files; device source paths therefore differ from originals.
- Maximum payload: 64 MB of files, 4096 files, 96 MB encoded message. Paths,
  filesystem aliases and file/directory conflicts are checked before installation.
- Native Swift sources/custom native runtime layouts require a separately built
  app. No Swift compiler runs on the device.
- No incremental transfer, breakpoints, remote inspector or live property editing.
- Logs are bounded; overflow is reported. Connection loss stops the game.

## Focused validation

`swift test --package-path PlayerConnect --scratch-path /tmp/ada-player-connect-build`
tests real loopback pairing, deploy/redeploy, log return, stop, disconnect,
unauthorized commands and installation validation. `EditorPlayerProjectTests`
in the editor package additionally covers packaging and loading through the real
AdaScript project builder. These tests do not replace a physical-device playtest.
