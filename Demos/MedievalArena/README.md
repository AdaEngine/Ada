# Medieval Arena

Portable AdaScript multiplayer sample for AdaEditor and AdaPlayer. The project
contains no Swift package and no native game sources. The precompiled
`multiplayer` capability transports typed input commands and authoritative state;
all Medieval Arena rules stay in this directory:

- `ArenaState.ada` owns player state and game constants;
- `ArenaInput.ada` maps configured actions into local/network input;
- `ArenaGameplay.ada` runs authoritative movement, sword hit tests, damage,
  three hearts, defeat/respawn, and publishes snapshots;
- `ArenaPresentation.ada` creates player/heart visuals and sword animation;
- `Assets/Scenes/Main.ascn` owns the populated TileMap and spawn markers.

## Run

Open this directory in AdaEditor and press Play. The checked-in configuration is
the authoritative Host on local TCP port `37778`.

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
