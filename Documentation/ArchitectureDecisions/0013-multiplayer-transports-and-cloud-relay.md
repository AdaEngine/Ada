# ADR-0013: Use Apple LAN networking and an AdaEngine Cloud relay

- Status: Accepted
- Date: 2026-09-20
- Implementation: Partial (foundation shipped)

## Context

Apple clients need local discovery without a Cloud dependency. Browser clients
cannot accept arbitrary inbound LAN connections and deployed HTTPS games cannot
reliably connect to an untrusted local WebSocket certificate. Internet player
hosting also cannot assume port forwarding or public addresses.

## Decision

Apple-to-Apple LAN sessions use Network.framework discovery and a reliable
connection owned by `AppleLocalTransport`. QUIC is the target protocol because
it supports secure reliable streams and a later best-effort datagram channel.
The local session identity is pinned and shown through an application-provided
verification UI. Multipeer Connectivity and RealityKit synchronization are not
runtime dependencies.

Internet sessions use `CloudWebSocketTransport`. All participants, including a
player Host, create an outbound WSS connection to `MultiplayerRelay`. Web uses
the same route and never attempts direct LAN hosting in v1.

AdaEngine Cloud exposes:

- authenticated session creation for an account Host;
- guest join by an eight-character code;
- single-use 60-second connection tickets sent in the first WebSocket message,
  never in the URL;
- Redis-backed room, code, and ticket TTLs;
- one relay process per environment in v1.

The relay validates session membership, frame size, rate, and star-topology
targets. It decodes only the routing envelope and does not persist gameplay
payloads. TLS terminates at Cloud; end-to-end encryption is not promised by v1.
Slow consumers have bounded queues and are disconnected rather than allowing
unbounded memory growth.

Multiplayer follows the existing Cloud regional rollout. Create requires an
authenticated account in an allowed region; guest join and connect require an
allowed region but no account. A feature flag can disable all multiplayer
routes independently.

## Consequences

- Host loss closes the room; the relay never becomes authoritative simulation.
- Native Linux, Windows, and Android receive the transport protocol and can
  provide adapters, but no built-in production adapter is required in v1.
- Horizontal relay scale requires session affinity or explicit room sharding
  and is deferred until the single-replica service has load evidence.
