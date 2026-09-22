# ADR-0011: Keep multiplayer transport-independent and optional

- Status: Accepted
- Date: 2026-09-20
- Implementation: Partial (foundation shipped)

## Context

AdaEngine needs one multiplayer model for a player-hosted game, a headless
authoritative process, local networking, and internet relay. RealityKit's scene
synchronization is convenient but Apple- and RealityKit-specific. Bevy's
networking ecosystem instead separates transport, messages, replication, and
presentation correction.

Networking callbacks must not retain or mutate `World`: AdaECS mutation is
valid only inside scheduled systems with declared access. Multiplayer must also
remain optional for offline games and replaceable for projects with a custom
backend.

## Decision

`AdaMultiplayer` is a separate SwiftPM library and an ordinary AdaEngine
`Plugin`. It is not part of `DefaultPlugins` and is not a SwiftPM build plugin.

The runtime has four layers:

1. `MultiplayerTransport` moves opaque bytes and publishes `Sendable` events.
2. A versioned binary envelope performs compatibility and framing.
3. Typed RPC and replication registries map stable wire identifiers to Codable
   values; Swift type names are never wire identity.
4. ECS systems drain received packets, mutate the world, capture authoritative
   state, and apply presentation interpolation.

`networkReceive`, `networkSend`, and `networkInterpolate` are canonical main
scheduler stages. Transport callbacks only enqueue values. Type-erased world
mutation runs with exclusive system access.

Third parties may supply a transport, codec, replication policy, or ordinary
AdaEngine plugin that registers components and messages. These extensions
receive scoped capabilities and never an unscheduled transport-to-`World`
escape hatch.

## Consequences

- Offline applications pay only for empty scheduler stages unless they install
  `MultiplayerPlugin`.
- Platform transports can evolve independently of game protocol semantics.
- A custom plugin must install after `MultiplayerPlugin` so its registrations
  enter the world-scoped registry before the first connection handshake.
- The foundation currently includes the registry, sessions, in-memory
  transport, WebSocket client, replication, and RPC. LAN QUIC and WASI runtime
  proof remain required before this ADR is fully implemented.
