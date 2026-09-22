# ADR-0012: Use host-authoritative replication and typed RPC

- Status: Accepted
- Date: 2026-09-20
- Implementation: Partial (foundation shipped)

## Context

The first multiplayer version must support responsive cooperative scenes
without committing AdaEngine to deterministic rollback. It must nevertheless
preserve enough protocol state to add prediction, reconciliation, unreliable
snapshots, and host migration later without replacing entity identity or RPC.

Automatically serializing every Codable ECS component would leak local render,
editor, and runtime state. Requiring every entity field to be wired manually
would lose the RealityKit-like authoring experience.

## Decision

The topology is a logical star. One Host owns the authoritative world. Peers
send input, commands, and requests to Host; only Host emits replicated state.
Peer-to-peer messages are routed and authorized through Host.

`ReplicatedEntity` opts an entity into replication. The host assigns its stable
`NetworkEntityID`; local `Entity.ID` never crosses the network. All component
types on that entity that were registered with a stable identifier and version
are synchronized automatically. Other components remain local.

The protocol carries spawn, component set/removal, and despawn operations.
Late joins receive a baseline followed by ordered deltas. Snapshot rate is
independent of fixed simulation rate and defaults to 20 Hz. Registered
interpolation functions update presentation state after authoritative capture,
so interpolated values are not sent back as host state.

RPC is typed:

- `NetworkCommand` is normally peer-to-host and one-way;
- `NetworkEvent` is normally host-to-peer and one-way;
- `NetworkRequest` has an associated Codable response, correlation identifier,
  timeout, and cancellation.

Messages are explicitly registered with direction, version, payload limit, and
stable identifier. Incoming messages become scheduler-scoped
`RemoteCommands`, `RemoteEvents`, or `RemoteRequests`; the protocol never calls
a Swift method selected by a remote string.

Every frame reserves protocol major/minor, session epoch, sequence, simulation
tick, type version, and correlation identity. The handshake includes game,
build, and schema identities. These fields are normative even where v1 uses
epoch zero and reliable ordered delivery.

## Deferred behavior

- Client prediction, input replay, reconciliation, rollback, lag compensation,
  spatial interest management, and component field deltas are later plugins.
- Host migration will use a new epoch and checkpoint. In v1, losing Host after
  the disconnect grace period ends the session.
- Snapshot capture may optimize with direct ECS change ticks, but the observable
  wire result must remain component-level deltas with baseline recovery.

The declarative Swift macro and AdaScript authoring surface, shared field-tagged
schema ABI, and removal of game-authored snapshot mailboxes are specified by
[ADR-0014](0014-declarative-multiplayer-schemas.md).
