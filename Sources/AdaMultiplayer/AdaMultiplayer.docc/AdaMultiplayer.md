# ``AdaMultiplayer``

Build host-authoritative local and internet multiplayer with replaceable
transports, automatic marker-based ECS replication, interpolation, and typed
RPC.

## Overview

Multiplayer is opt-in and is not included in `DefaultPlugins`. Add the core
plugin before the plugin that declares your game's network schema:

```swift
import AdaMultiplayer

struct GameNetworkPlugin: Plugin {
    func setup(in app: borrowing AppWorlds) {
        app
            .registerReplicatedComponent(
                PlayerState.self,
                id: "game.player-state",
                version: 1
            )
            .registerNetworkCommand(MovePlayer.self)
    }
}

let transport = AppleLocalTransport(
    mode: .host(serviceName: "My Game"),
    configureQUIC: configurePinnedLocalIdentity
)
let configuration = MultiplayerConfiguration(
    role: .host,
    compatibility: NetworkCompatibility(
        gameIdentifier: "com.example.game",
        buildIdentifier: "1.0"
    )
)

app
    .addPlugin(MultiplayerPlugin(configuration: configuration, transport: transport))
    .addPlugin(GameNetworkPlugin())
```

Add ``ReplicatedEntity`` to an authoritative entity. Every component on that
entity that was explicitly registered is included automatically; other ECS
state remains local:

```swift
world.spawn("Player") {
    ReplicatedEntity()
    NetworkOwner(peer: controllingPeer)
    Transform()
    PlayerState(health: 100)
}
```

Peers send typed commands to Host through the ``MultiplayerSession`` resource.
Gameplay systems consume the values through ``RemoteCommands``:

```swift
struct MovePlayer: NetworkCommand {
    static let networkIdentifier = "game.move-player"
    var direction: Vector2
}

@PlainSystem
struct ApplyRemoteMovement {
    @RemoteCommands<MovePlayer> private var commands

    init(world: World) {}

    func update(context: UpdateContext) async {
        for command in commands {
            // Validate command.source and apply authoritative gameplay rules.
        }
    }
}
```

## Transport choices

- ``InMemoryTransport`` is deterministic infrastructure for tests and embedded
  sessions.
- `AppleLocalTransport` advertises or joins a Bonjour QUIC service on Apple
  platforms.
- ``CloudWebSocketTransport`` connects Apple and browser clients to the
  AdaEngine Cloud relay with a single-use connection ticket.
- A custom transport implements ``MultiplayerTransport`` and never accesses an
  AdaECS `World` directly.

The first protocol version uses reliable ordered state snapshots and visual
interpolation. Prediction, rollback, host migration, and peer-to-peer authority
are intentionally not implied by the API.
