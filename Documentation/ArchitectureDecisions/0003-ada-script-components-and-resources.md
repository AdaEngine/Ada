# ADR-0003: Generate native backing types for Ada Script data

- Status: Accepted
- Date: 2026-08-31
- Implementation: Partial (foundation shipped)

## Implementation status

Last verified: 2026-08-31.

Shipped:

- [x] `AdaScriptCompilerCore` parses deterministic `@component` and
  `@resource` schemas from the target source map.
- [x] Stable IDs, duplicate declaration names, duplicate IDs, missing defaults,
  and unsupported defaults are rejected before Swift compilation.
- [x] The build plugin generates native Swift `Component` and `Resource`
  backing structs for `Bool`, `Int64`, `Double`, and `String` fields.
- [x] Generated components receive editor field descriptors and pointer access
  through the existing `@Component` macro.
- [x] Generated types register both their Gravity declaration name and stable
  ID in `RuntimeTypeRegistry`.
- [x] Swift and Editor code can insert a generated component default by stable
  ID without referencing its private Swift type.
- [x] Resources with `autoInsert: true` are inserted into the main world before
  the generated script module plugin is installed.
- [x] `@res` resolves a generated or registered resource by declaration name or
  stable ID and exposes its reflected fields through a pointer-backed view.
- [x] Required missing resources produce runtime diagnostics; optional bindings
  expose `available()` and remain valid when the resource is absent.
- [x] Resource writes update the ECS change tick and participate in scheduler
  conflict detection. The current implementation conservatively requests write
  access for every `@res` binding.

Remaining before this ADR is implemented:

- [ ] Add vector, color, enum, entity-reference, and asset-reference schemas.
- [ ] Infer resource read/write access from property use and support an explicit
  access override instead of conservatively requesting write access.
- [ ] Add dynamic world APIs for removing, coding, and mutating a
  generated component without naming its private Swift backing type.
- [ ] Encode stable component/resource IDs in scenes and implement aliases and
  schema migration diagnostics.
- [ ] Move import parsing and complete schema analysis into one authoritative
  compiler AST shared by runtime, generator, and LSP.
- [ ] Expose generated schemas and fields to Editor inspection and completion.

## Context

Ada Script must be able to declare ECS components and singleton resources. An
Ada Script component should participate in archetype matching, chunk storage,
pointer-based query iteration, scheduler conflicts, change detection, scene
coding, and Editor inspection even if ordinary Swift source does not have a
convenient typed API for it.

AdaECS currently identifies typed components and resources through Swift
metatypes. `BlobArray` allocation and destruction use `MemoryLayout<T>` and
typed deinitializers. A fully runtime-defined raw layout would therefore require
a broad rewrite of component layout, moves, copies, destruction, coding, and
reflection.

The SwiftPM Ada Script build plugin already emits Swift source before the target
is compiled. It can provide native backing types without changing the public
Ada Script syntax.

## Decision

### Ada Script component declarations

Components are declared in Ada Script:

```ada
@component(id: "game.health")
struct Health {
    @export
    var current = 100.0;

    @export
    var maximum = 100.0;
}
```

The component identifier is stable serialization and runtime metadata. It does
not depend on a generated Swift symbol name.

Component declarations may be imported and used symbolically:

```ada
import { Health } from "./GameplayData.ada";

@query(Health)
var entities;
```

Imports and target-level module discovery follow
[ADR-0001](0001-ada-script-annotation-modules.md). Query iteration and access
inference follow [ADR-0002](0002-ada-script-ecs-query-api.md).

### Ada Script resource declarations

Resources use the same schema model:

```ada
@resource(
    id: "game.balance",
    autoInsert: true
)
struct GameBalance {
    @export
    var playerSpeed = 8.0;

    @export
    var enemyDamage = 10.0;
}
```

`autoInsert: true` creates the resource from its declared defaults when the
script module is installed. A resource without `autoInsert` must be inserted by
application setup or an exclusive startup capability.

Systems declare resource bindings with `@res`:

```ada
@res
var balance: GameBalance;

@res(optional: true)
var debugSettings: DebugSettings;
```

Resource read and write access is inferred from property use using the same
rules as component access. Explicit `access: "read"` or `access: "write"` is
available when static inference is impossible.

The first implementation conservatively treats every `@res` as writable while
the compiler access-analysis pass is still pending. An optional resource is
checked before field access:

```ada
if (debugSettings.available()) {
    debugSettings.enabled = true;
}
```

### Generated Swift backing types

The build plugin parses the complete target-level Ada Script module graph and
generates internal Swift types for every `@component` and `@resource` schema.
A generated component is conceptually equivalent to:

```swift
@Component
struct AdaGenerated_Game_Health: Codable {
    var current: Double = 100
    var maximum: Double = 100
}
```

Generated types provide:

- `Component` or `Resource` conformance;
- native size, alignment, initialization, move, and deinitialization behavior;
- field reflection descriptors;
- stable Ada Script coding names;
- default values;
- generated registration code;
- native scheduler identities and storage pointers.

Generated Swift symbol names are implementation details. Scene files and Ada
Script metadata use declared stable identifiers such as `game.health`.

The initial schema supports:

- booleans;
- signed integers;
- floating-point values;
- strings;
- vectors and colors supported by engine field reflection;
- enums with stable case names;
- entity references;
- asset references supported by AdaEngine coding.

Closures, arbitrary Gravity instances, untyped maps, VM-owned lists, and other
objects without a stable native schema cannot be stored as component or resource
fields.

### Swift interoperability

Typed Swift interoperability is not required for the first implementation.
Swift may inspect and mutate generated data through a dynamic API using stable
component and field names.

```swift
world.dynamicComponent("game.health", from: entity)
world.setDynamicComponentField(
    "current",
    value: .double(50),
    component: "game.health",
    entity: entity
)
```

A future generator may expose a deterministic public namespace for generated
types, but that API is not part of this decision.

### Coding

Generated components and resources are Codable. Their encoded identity is the
stable Ada Script identifier, not the generated Swift type name. Renames require
explicit aliases or a schema migration rather than silently losing data.

Schema changes that alter native layout require rebuilding the Swift target.
Runtime hot reload may update behavior and compatible defaults but cannot change
an active native component layout without a world migration.

## Consequences

- Script-defined data uses ordinary AdaECS archetypes, chunks, ticks, coding,
  and scheduler rules.
- The first implementation does not require a runtime raw-layout rewrite of
  AdaECS.
- The build generator must use the authoritative Gravity annotation parser,
  not a second ad-hoc source scanner.
- The generator validates duplicate stable IDs, unsupported field types,
  recursive layouts, invalid defaults, and conflicting imports before Swift
  compilation.
- Generated source becomes a target build input and must be deterministic for
  identical module graphs.
- The Editor and LSP use the same schema metadata for completion and inspection.

## Rejected alternatives

### Store every script component in one dictionary component

Rejected because individual script components would not participate in
archetype filtering, scheduler access, native column iteration, or efficient
change detection.

### Store Gravity object handles as component values

Rejected because pointer iteration would only access handles while component
fields remained VM maps, and component lifetime would become coupled to VM GC.

### Generalize all AdaECS storage to arbitrary runtime layouts first

Deferred because it is a large, unsafe storage rewrite and is not necessary to
deliver native script-defined components. It may be reconsidered independently.
