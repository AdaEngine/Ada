# AdaEngine Architecture Decision Records

This directory records accepted architectural decisions for AdaEngine. An ADR
describes the intended design even when its implementation is still planned.

## Status values

- **Proposed**: under discussion and not yet binding.
- **Accepted**: the design is the source of truth for implementation work.
- **Superseded**: replaced by a newer ADR.
- **Rejected**: considered but deliberately not selected.

## Implementation values

- **Planned**: no production slice of the decision has shipped.
- **Partial (foundation shipped)**: a tested production slice has shipped, but
  the ADR's own implementation checklist still has open requirements.
- **Implemented**: every normative requirement in the ADR is shipped and its
  validation is recorded.

## Ada Script decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0001](0001-ada-script-annotation-modules.md) | Accepted | Partial (foundation shipped) | Annotation-driven modules, imports, and discovery without `main()` |
| [ADR-0002](0002-ada-script-ecs-query-api.md) | Accepted | Partial (foundation shipped) | Iterator-based ECS queries, canonical filter syntax, and inferred access |
| [ADR-0003](0003-ada-script-components-and-resources.md) | Accepted | Partial (foundation shipped) | Ada Script-defined components and resources backed by generated Swift types |
| [ADR-0004](0004-ada-script-world-capabilities.md) | Accepted | Partial (foundation shipped) | Capability-scoped world access and deferred structural changes |
| [ADR-0005](0005-scriptable-objects-and-coding.md) | Accepted | Implemented | Scriptable object lifecycle, registration, and scene coding |
| [ADR-0006](0006-ada-script-adaui-integration.md) | Accepted | Partial (foundation shipped) | Native AdaUI view graphs, state, bindings, snapshots, and event routing for AdaScript |
| [ADR-0007](0007-ada-script-runtime-and-hot-reload.md) | Accepted | Planned | Transactional module generations, safe-point hot reload, and runtime failure isolation |
| [ADR-0008](0008-adascript-projects-on-ipados.md) | Accepted | Partial (project foundation shipped) | Portable AdaScript projects, iPadOS runtime sessions, Files/iCloud, and Git ownership |
| [ADR-0009](0009-adascript-runtime-configuration.md) | Accepted | Partial (foundation shipped) | Declarative entry plans, plugin presets, typed settings, and runtime-window configuration |
| [ADR-0010](0010-adascript-native-adaui-extension-registry.md) | Accepted | Planned | Versioned descriptors and host factories for native AdaUI views and modifiers used by AdaScript |

## Multiplayer decisions

| ADR | Status | Implementation | Decision |
| --- | --- | --- | --- |
| [ADR-0011](0011-multiplayer-runtime-boundaries.md) | Accepted | Partial (foundation shipped) | Optional transport-independent multiplayer runtime and plugin extension model |
| [ADR-0012](0012-host-authoritative-replication-and-rpc.md) | Accepted | Partial (foundation shipped) | Host-authoritative marker replication, interpolation, and typed RPC |
| [ADR-0013](0013-multiplayer-transports-and-cloud-relay.md) | Accepted | Partial (foundation shipped) | Apple LAN transport and region-gated AdaEngine Cloud WebSocket relay |
