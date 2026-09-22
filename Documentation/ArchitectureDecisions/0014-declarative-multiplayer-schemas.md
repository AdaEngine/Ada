# ADR-0014: Generate declarative multiplayer schemas for Swift and AdaScript

- Status: Accepted
- Date: 2026-09-22
- Implementation: Partial (Swift and AdaScript command foundations shipped)

## Implementation status

Last verified: 2026-09-22.

Shipped:

- [x] Portable network type and field descriptor metadata with stable
  compatibility signatures.
- [x] Swift `@ReplicatedComponent`, `@NetworkCommand`, `@NetworkField`, and
  `@LocalOnly` macros.
- [x] Generated `Component`, `Codable`, `Sendable`, and
  `NetworkReplicatedComponent` conformances.
- [x] Implicit `ReplicatedEntity` required-component insertion.
- [x] Numeric field-tagged JSON coding that excludes local-only state.
- [x] Descriptor-driven component registration and schema digest integration.
- [x] In-memory Host/Peer proof covering generated registration, automatic
  marker insertion, replication, local-state exclusion, and typed command
  routing.
- [x] AdaScript parsing and VM lowering for `@network_command`,
  `@network_field`, `@remote_commands`, and `@replicated_component`.
- [x] Portable AdaScript typed command send/receive with authenticated source,
  numeric wire tags, and no script-authored mailbox or sequence.
- [x] Cross-language Swift/AdaScript command schema digest parity.
- [x] Build-plugin native backing generation and registration for AdaScript
  replicated components, including local-field coding exclusion.
- [x] Medieval Arena peer input migrated from positional mailbox envelopes to
  a typed AdaScript command.

Remaining:

- [ ] Generated Swift event, request, and network-module macros.
- [ ] Portable runtime layouts for custom AdaScript replicated components; the
  build-plugin native path is implemented.
- [ ] Field-level `.state`, `.latest`, `.initialOnly`, delivery, and
  interpolation behavior in the runtime.
- [ ] Medieval Arena authoritative state migration and old snapshot mailbox
  deprecation.

## Context

[ADR-0012](0012-host-authoritative-replication-and-rpc.md) establishes a
host-authoritative topology, marker-based ECS replication, and typed commands,
events, and requests. The shipped foundation correctly keeps transport,
framing, RPC registration, authoritative capture, and interpolation separate.
Its authoring surface is nevertheless too low-level for game code.

Swift components currently require an explicit `Component & Codable &
Sendable` declaration followed by manual registration with a stable identifier.
AdaScript has no typed network-model surface over that registry. Its first
multiplayer bridge therefore exposes a mutable mailbox containing detached
arrays and explicit sequence counters. Medieval Arena uses that mailbox to
flatten all player state into a positional array, increment a publication
sequence, broadcast it as an event, decode it by numeric offsets, and rebuild a
second local state store.

That bridge proves the transport and scheduling path, but it puts protocol work
in every game:

- commands, source identity, and publication state are manually enveloped;
- durable state is sent through RPC events rather than ECS replication;
- field order becomes an undocumented wire schema;
- user code owns sequence counters, baseline-like payloads, and latest-value
  selection;
- Swift and AdaScript cannot declare the same protocol semantics through one
  descriptor model;
- the engine cannot validate authority, evolution, interpolation, visibility,
  or delivery at the field declaration.

Godot separates annotated RPC from property synchronization. Bevy networking
libraries separate client/server messages from marker- and rule-based ECS
replication. RealityKit makes synchronization identity and ownership part of
the entity/component model. AdaEngine should keep its ECS-native,
host-authoritative runtime while providing comparable authoring ergonomics.

## Decision

### Keep RPC and replication semantically separate

Game code uses three concepts:

1. **Commands** express peer intent to Host.
2. **Events and requests** represent discrete occurrences or correlated work.
3. **Replicated components** hold authoritative state over time.

Commands and events must not be used as application-authored state snapshots.
Baseline capture, deltas, sequencing, acknowledgement, late-join recovery,
spawn, despawn, component removal, coalescing, and interpolation are runtime
responsibilities.

The canonical rule is:

> Commands express intent. Events describe occurrences. Replicated components
> hold truth. Snapshots are an internal transport detail.

### Generate one descriptor ABI from both languages

Swift macros and the AdaScript compiler emit the same dependency-neutral schema
model. A network type descriptor contains at least:

```swift
public struct NetworkTypeDescriptor: Sendable {
    public let typeID: String
    public let version: UInt16
    public let kind: NetworkTypeKind
    public let authority: NetworkAuthority
    public let delivery: NetworkDelivery
    public let channel: NetworkChannel
    public let maximumPayloadSize: Int
    public let fields: [NetworkFieldDescriptor]
}
```

A field descriptor contains at least:

```swift
public struct NetworkFieldDescriptor: Sendable {
    public let tag: UInt16
    public let wireType: NetworkWireType
    public let replication: FieldReplicationMode
    public let interpolation: FieldInterpolationMode
}
```

Descriptors also own generated baseline encoding, delta encoding, application,
and interpolation operations required by the native registry. Closures that
touch ECS storage stay in the native runtime descriptor; the portable schema
manifest contains only stable metadata.

Type identifiers and positive numeric field tags are wire identity. Swift or
AdaScript declaration names, source order, generated Swift symbols, and
`Entity.ID` are never wire identity. A field tag must not be reused for a
different meaning after release.

The schema digest includes type identifiers, versions, kinds, directions,
delivery modes, field tags, wire types, and replication modes. The same logical
schema authored in Swift or AdaScript produces the same digest.

### Make Swift replicated components self-contained

The canonical Swift declaration is:

```swift
@ReplicatedComponent(
    id: "arena.player",
    version: 1,
    authority: .host,
    visibility: .allPeers
)
struct ArenaPlayer {
    @NetworkField(1, mode: .latest, interpolate: .linear)
    var position: Vector2

    @NetworkField(2, mode: .state)
    var health: UInt8

    @NetworkField(3, mode: .state)
    var facing: Facing

    @NetworkField(4, mode: .state)
    var attackSequence: UInt32

    @NetworkField(5, mode: .latest)
    var respawnRemaining: Float

    @NetworkField(6, mode: .initialOnly)
    var variant: UInt8

    @LocalOnly
    var consumedInputSequence: UInt32
}
```

`@ReplicatedComponent` is an attached extension macro. It synthesizes
`Component`, `Sendable`, and the internal network-replication conformance. Game
code does not repeat `: Component`. An explicit conformance may remain
source-compatible during migration, but documentation and generated fixes use
the compact spelling.

The generated `RequiredComponents` includes `ReplicatedEntity`. Attaching any
replicated component therefore opts the entity into replication and provides
network identity automatically. An explicit `ReplicatedEntity` remains useful
for an entity that replicates only separately registered built-in components.
`NetworkOwner` remains optional metadata and does not grant mutation authority.

Only properties marked `@NetworkField` enter the wire schema. Unannotated
stored properties are local. `@LocalOnly` is optional documentary syntax that
also asks the macro to diagnose any accidental network annotation on the same
property. Computed properties never enter the schema.

The macro must diagnose at compile time:

- an empty or duplicate type identifier;
- field tag zero, duplicate tags, or unsupported field types;
- non-`Sendable` stored state when the type cannot safely conform;
- incompatible annotation combinations;
- a requested interpolation mode unsupported by the field type;
- a replicated type declared as a resource or system;
- missing defaults when generated decoding requires one.

The macro generates field-specific coding rather than encoding the entire
component through declaration order. `Codable` may be synthesized as a
temporary adapter for the v1 registry, but it is not the long-term network ABI
and must not include local-only fields.

### Generate typed Swift messages

Swift commands use model macros:

```swift
@NetworkCommand(
    id: "arena.player-input",
    version: 1,
    direction: .peerToHost,
    delivery: .unreliableSequenced,
    channel: "input"
)
struct PlayerInput {
    @NetworkField(1)
    var movement: Vector2

    @NetworkField(2)
    var attackSequence: UInt32
}
```

`@NetworkEvent` and `@NetworkRequest(response:)` use the same schema rules.
The macros synthesize the appropriate `NetworkMessage` conformance, stable
identity, version, detached codec, and descriptor. Source identity always comes
from the authenticated `RemoteCommand`, `RemoteEvent`, or `RemoteRequest`
context and is never trusted from payload data.

Sending and receiving stay ECS-native:

```swift
try await multiplayer.send(
    PlayerInput(movement: movement, attackSequence: attackSequence)
)

@RemoteCommands<PlayerInput>
private var playerInputs
```

The runtime owns transport sequence numbers. A gameplay counter such as
`attackSequence` is allowed because it describes gameplay semantics, not packet
publication.

Function-level `@RPC` syntax may later lower to a generated message and handler,
but it is sugar over descriptors. The protocol never invokes a Swift or
AdaScript method selected by an untrusted remote string.

### Give AdaScript the same declarations and semantics

AdaScript replicated data extends the generated-component model from
[ADR-0003](0003-ada-script-components-and-resources.md):

```ada
@replicated_component(
    id: "arena.player",
    version: 1,
    authority: "host",
    visibility: "all_peers"
)
struct ArenaPlayer {
    @network_field(1, mode: "latest", interpolate: "linear")
    var position = Vector2.ZERO;

    @network_field(2, mode: "state")
    var health = 3;

    @network_field(3, mode: "state")
    var facing = 3;

    @network_field(4, mode: "state")
    var attackSequence = 0;

    @network_field(5, mode: "latest")
    var respawnRemaining = 0.0;

    @network_field(6, mode: "initial_only")
    var variant = 0;

    @local
    var consumedInputSequence = 0;
}
```

`@replicated_component` implies `@component`; authors do not stack both
annotations. Its generated Swift backing type conforms to the same native
protocols and emits the same descriptor ABI as a Swift declaration.

Typed AdaScript messages use parallel syntax:

```ada
@network_command(
    id: "arena.player-input",
    version: 1,
    direction: "peer_to_host",
    delivery: "unreliable_sequenced",
    channel: "input"
)
struct PlayerInput {
    @network_field(1)
    var movement = Vector2.ZERO;

    @network_field(2)
    var attackSequence = 0;
}
```

The script-facing runtime surface is typed:

```ada
@res
var multiplayer: Multiplayer;

@remote_commands(PlayerInput)
var playerInputs;

multiplayer.send(
    PlayerInput(
        movement: Vector2(moveX, moveY),
        attackSequence: attackSequence
    )
);
```

Received values expose `message.source` and `message.value`. They do not expose
or require a positional `[source, sequence, payload]` envelope. Replicated
components participate in ordinary `@query` declarations on Host and peers;
presentation reads the component applied by `networkReceive` rather than
rebuilding a parallel dictionary.

The AdaScript build pipeline discovers annotated network declarations across
the resolved module graph, validates them using the authoritative compiler AST,
generates native backing types and descriptors, and emits a portable schema
manifest for the language server, Editor, compatibility handshake, and
precompiled hosts. A second regex or ad-hoc source scanner is forbidden.

### Require explicit module registration without runtime scanning

Swift packages group descriptors into one generated module:

```swift
@NetworkModule(
    commands: [PlayerInput.self],
    components: [ArenaPlayer.self]
)
enum ArenaNetwork {}
```

Application setup performs one explicit registration after
`MultiplayerPlugin`:

```swift
app.registerNetworkModule(ArenaNetwork.self)
```

This root makes package composition, duplicate diagnostics, schema digest, and
startup ordering deterministic. Process-wide metatype scanning and implicit
global registration are forbidden.

AdaScript modules are registered by their generated project plugin, so a
portable script project does not need a Swift registration site. A hybrid
project may register generated AdaScript and native Swift network modules into
the same world-scoped registry; duplicate stable identifiers are blocking
startup diagnostics.

### Define field replication semantics

The initial field modes are:

- `.state`: durable authoritative state. The runtime must eventually converge
  after packet loss through acknowledgement, resend, or baseline recovery.
- `.latest`: latest-wins streaming state. Intermediate values may be coalesced
  or discarded; an older sequence never overwrites a newer value.
- `.initialOnly`: included in spawn and recovery baselines but omitted from
  ordinary deltas unless the entity is recreated.

The initial interpolation modes are `.none`, `.linear`, and a descriptor-owned
custom interpolator. Interpolation is presentation-only. Interpolated peer
values never become authoritative input and are never echoed by Host.

Delivery modes for messages are `.reliableOrdered`, `.unreliable`, and
`.unreliableSequenced`. A transport may provide stronger delivery than
requested, but the runtime must still preserve coalescing and stale-packet
semantics. Capability negotiation rejects a session when a required semantic
cannot be provided.

Authority is validated before application:

- Host is the only writer of replicated gameplay components in v1;
- peer-to-host commands are accepted only from a compatible connected peer;
- host-to-peer events are accepted only from the authenticated Host path;
- `NetworkOwner` identifies whose intent controls an entity but does not allow
  a peer to mutate the component directly.

Visibility defaults to all compatible peers. Descriptor-level visibility and
the runtime `ReplicationPolicy` compose with logical AND. Per-peer spatial
interest management remains deferred.

### Preserve safe protocol evolution

Compatible evolution may add a field with a new tag and a default. Renaming a
source property while retaining its tag and semantics is compatible. Removing a
field reserves its tag. Changing a wire type, replication meaning, authority,
or message direction requires a version change and an explicit compatibility or
migration path.

Unknown compatible fields are skipped. Missing optional fields use declared
defaults. Required fields, incompatible versions, invalid enum values, payload
limit violations, and duplicate identities produce typed protocol diagnostics
rather than traps or partially applied state.

The first implementation may continue using JSON inside the existing bounded
wire envelope for debuggability. The descriptors, numeric field tags, and
compatibility rules are codec-independent so a later compact binary codec does
not change the authoring API.

### Migrate Medieval Arena to authoritative ECS state

Medieval Arena is the acceptance project for this ADR. Its target design is:

- `PlayerInput` is a typed peer-to-host command;
- each player is an entity containing generated `ArenaPlayer`, `Transform`, and
  presentation components;
- `ArenaPlayer` automatically requires `ReplicatedEntity`;
- Host systems consume `RemoteCommands<PlayerInput>` and mutate ECS components;
- peer presentation queries replicated components directly;
- attack animation is driven by a replicated gameplay counter or a typed event;
- spawn, defeat, respawn, late join, and disconnect use entity/component
  replication rather than a script-owned player dictionary.

The migration removes `AdaScriptMultiplayerState.publishedSnapshot`,
`publishedSnapshotSequence`, `receivedSnapshot`, `outgoingCommand`,
`outgoingCommandSequence`, and positional command envelopes from the demo path.
The generic mailbox may remain temporarily for source compatibility, but it is
deprecated for new project code and is not the declarative API.

## Implementation plan

1. Introduce public descriptor metadata, field tags, authority, delivery,
   replication modes, and codec-independent schema digest computation.
2. Extend the native replication registry to consume generated descriptors and
   support field-aware baseline/delta application without encoding local-only
   state.
3. Add Swift `@ReplicatedComponent`, message, field, local-only, and network
   module macros with expansion diagnostics and generated registration.
4. Extend the authoritative AdaScript schema parser and Swift generator with
   replicated components, messages, manifests, and Editor/LSP metadata.
5. Add typed AdaScript send/receive bindings and generated query integration;
   do not route the new API through mutable array mailboxes.
6. Add `.state`, `.latest`, `.initialOnly`, interpolation, coalescing, baseline
   recovery, and transport-capability behavior.
7. Migrate Medieval Arena and remove its handwritten snapshot protocol.
8. Deprecate the old mailbox fields after migration and document a bounded
   compatibility window before removal.

## Validation requirements

Implementation is not complete until all of the following pass:

- Swift macro expansion tests prove implied `Component`, required
  `ReplicatedEntity`, stable tags, local-only exclusion, and diagnostics.
- AdaScript compiler tests prove the parallel declarations emit descriptors
  matching Swift golden fixtures byte-for-byte or field-for-field.
- Schema tests cover rename, compatible field addition, reserved tags,
  incompatible type changes, duplicate identities, and digest stability.
- In-memory host/peer tests cover command source authentication, spawn,
  component set/removal, despawn, late join, disconnect, and visibility.
- Loss/reordering tests prove `.state` convergence and `.latest` stale-update
  rejection independently of a reliable local transport.
- Interpolation tests prove presentation values are not captured back into
  authoritative state.
- Mixed Swift/AdaScript modules complete a handshake with the same schema and
  reject incompatible schemas before gameplay payloads are applied.
- Medieval Arena runs as real Host and Peer instances without any
  game-authored snapshot payload or publication sequence.

## Consequences

- Ordinary multiplayer game code declares intent and ECS state instead of a
  custom serialization loop.
- Swift and AdaScript share one protocol model, compatibility digest, and
  runtime registry.
- Stable field tags add small declaration cost but make source reordering and
  renaming safe.
- Explicit network-module registration preserves deterministic plugin setup and
  avoids fragile runtime discovery.
- Field-aware descriptors make the registry more complex than whole-component
  `Codable`, but they prevent local-state leakage and enable future compact
  deltas without another authoring API migration.
- The existing wire envelope, scheduler stages, transport isolation, host
  authority, and marker replication remain valid foundations.

## Rejected alternatives

### Improve the generic AdaScript snapshot mailbox

Rejected because a more convenient snapshot builder would still make every
game own baselines, deltas, sequence selection, state duplication, and schema
evolution outside ECS replication.

### Treat every component property as replicated

Rejected because render handles, editor state, caches, local input, VM objects,
and platform resources must not cross the network implicitly. Network fields
remain opt-in even though entity replication becomes automatic when a
replicated component is attached.

### Require both `@ReplicatedComponent` and `: Component`

Rejected as redundant authoring noise. The macro owns the ECS and networking
conformances and diagnoses declarations it cannot safely synthesize.

### Use source field names or declaration order as wire identity

Rejected because harmless renames or reordering would silently break protocol
compatibility. Positive numeric tags are explicit and stable.

### Discover Swift schemas through process-wide reflection

Rejected because registration order, package composition, duplicate handling,
precompiled hosts, and compatibility digests must be deterministic before a
connection is accepted.

### Invoke remote methods by name

Rejected because it couples the wire protocol to implementation symbols,
weakens registration and direction validation, and exposes an unnecessary
dynamic dispatch surface. Function annotations may generate typed messages but
do not change the underlying protocol.
