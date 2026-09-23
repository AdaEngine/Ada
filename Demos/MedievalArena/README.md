# Medieval Arena

Portable AdaScript multiplayer sample for AdaEditor and AdaPlayer. The project
contains no Swift package and no native game sources. The precompiled
`multiplayer` capability transports typed input commands and authoritative state;
all Medieval Arena rules stay in this directory:

- `ArenaState.ada` declares the replicated `ArenaPlayer` component and game constants;
- `ArenaInput.ada` maps configured actions into local/network input; the
  command is declared with method-level `@rpc` sugar in `ArenaState.ada`;
- `ArenaGameplay.ada` runs authoritative movement, sword hit tests, damage,
  three hearts, and defeat/respawn on ECS components;
- `ArenaPresentation.ada` creates player/heart visuals and sword animation;
- `Assets/Scenes/Main.ascn` owns the populated TileMap and spawn markers.

## Run in a browser

Open this directory in AdaEditor, keep the checked-in `Web` run destination, and
press Run. The browser lobby can create a room, join an eight-character room
code, or start a local solo match. Room play uses the AdaEngine Cloud relay;
solo runs without a relay connection. A browser with WebGPU is required.

## Run on macOS

Select the `macOS` run destination in AdaEditor and press Run. The project's
local TCP settings use the authoritative Host on port `37778`.

To run a Peer from a second copy of the project, change only these values in
`.ada/project.json`:

```json
"multiplayer": {
  "host": "::1",
  "peerIndex": 2,
  "port": 37778,
  "role": "peer"
}
```

Use the Host's LAN address instead of `::1` for another Mac on the same network.

Controls: `WASD` or arrow keys to move, `Space` to swing the sword. The Host owns
the world, players have three hearts, and defeated players respawn after two
seconds.

Tiles are from Kenney Tiny Dungeon and are licensed CC0 1.0.
