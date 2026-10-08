# ADR-0005: Unify scriptable object lifecycle and coding

- Status: Accepted
- Date: 2026-08-31
- Implementation: Implemented

## Implementation status

Last verified: 2026-08-31.

- [x] Native and Gravity scriptable objects share `ScriptableObjectRegistry`,
  stable identifiers, versions, aliases, exported-field metadata, and the same
  polymorphic scene envelope.
- [x] Unknown identifiers and unsupported future versions produce typed errors.
- [x] Decoded objects remain detached; `ready`, `update`, `fixedUpdate`,
  `event`, and `destroy` have explicit scoped lifecycle semantics.
- [x] `destroy` runs once after component/entity detachment rather than relying
  on object deallocation.
- [x] The build plugin discovers `@scriptable` declarations and registers their
  module runtime before scene objects are created.
- [x] Gravity instances are owned by a shared module VM while serialized state
  contains only detached `@export` values.
- [x] `@component` and `@res` bindings are transient checked capabilities;
  required components are validated before `ready` and resource writes update
  ECS change ticks.
- [x] Immediate-mode `updateGUI` was removed from the native lifecycle and demos
  were migrated to scoped contexts.

Component and resource bindings currently declare conservative write access.
Narrowing read-only bindings is a scheduler optimization rather than a missing
capability or safety boundary.

## Context

AdaScene currently provides a Unity-like `ScriptableObject` lifecycle stored in
`ScriptableComponents`. The base class contains custom exported-field encode and
decode methods, but the heterogeneous script collection does not have a complete
polymorphic coding and type-registration model.

Ada Script also needs an attached object model for small entity-specific
controllers. It should share lifecycle and scene representation with native
Swift scriptable objects without becoming the high-performance alternative to
ECS systems.

## Decision

### Role

Scriptable objects are the object-per-entity convenience API for controllers,
cameras, UI behavior, and other low-cardinality logic. Iterator-based systems
from [ADR-0002](0002-ada-script-ecs-query-api.md) remain the data-oriented path
for large entity sets.

### Ada Script declaration

An Ada Script object is declared without a plugin manifest:

```ada
@scriptable(
    id: "game.player-controller",
    version: 1
)
class PlayerController {
    @export(range: [0.0, 20.0], step: 0.1)
    var speed = 8.0;

    @export
    var jumpImpulse = 6.0;

    @component(required: true)
    var transform: Transform;

    @component
    var velocity: Velocity;

    @res
    var input: Input;

    func ready(context) {
    }

    func update(context) {
        var position = transform.position;
        position[0] += velocity.value[0] * speed * context.deltaTime;
        transform.position = position;
    }

    func fixedUpdate(context) {
    }

    func event(events, context) {
    }

    func destroy(context) {
    }
}
```

`@component` and `@res` declarations create capability bindings for the attached
entity. Their read and write access is inferred from lifecycle methods. They are
transient and are never encoded.

The current compiler uses a safe conservative form of inference: every bound
component or resource is declared writable. This may serialize more work but
does not hide access from the scheduler.

Scriptable objects do not provide an immediate-mode `drawGUI` lifecycle. They
mount, dismiss, or send inputs to declarative Ada Script views described by
[ADR-0006](0006-ada-script-adaui-integration.md). This keeps layout, state,
focus, hit testing, accessibility, and rendering in the native AdaUI graph.

### Native Swift API

Native Swift scriptable object types use the same stable registration model and
scene envelope. A Swift-facing annotation or generated descriptor records a
stable identifier, version, aliases, exported properties, required components,
and declared capabilities.

Scriptable object installation registers all known native and Ada Script types
before scene decoding. Registration must be explicit and deterministic rather
than relying on Objective-C class lookup.

Lifecycle APIs receive scoped context values instead of retaining hidden world
and input references. Compatibility with the existing Swift API is not a
constraint for the new design because this decision is implemented as a
coordinated engine API change.

Native types register explicitly before decoding:

```swift
try ScriptableObjectRegistry.register(
    PlayerController.self,
    identifier: "game.player-controller",
    version: 2,
    aliases: ["PlayerController"]
)
```

### Scene representation

`ScriptableComponents` uses explicit polymorphic coding:

```json
{
  "scripts": [
    {
      "type": "game.player-controller",
      "version": 1,
      "payload": {
        "speed": 12.0,
        "jumpImpulse": 6.0
      }
    }
  ]
}
```

The encoded envelope contains:

- a stable type identifier;
- a schema version;
- exported property payload;
- future migration metadata when required.

Entity bindings, world context, input, VM handles, query rows, awake state, and
other lifecycle state are not encoded.

Renames use explicit aliases:

```ada
@scriptable(
    id: "game.player-controller",
    version: 2,
    aliases: ["PlayerController", "game.player"]
)
class PlayerController {
}
```

Unknown types are never silently discarded. Runtime decoding reports a typed
error. The Editor may preserve an unresolved type and its original payload as a
round-trippable placeholder so opening and saving a scene does not destroy data.

### Lifecycle after decoding

After decoding, a script object is unattached and not awake. Attachment binds
its entity and declared capabilities. `ready` runs once after successful
attachment. Decoding does not call gameplay lifecycle methods.

`destroy` runs once when the object is detached or its containing entity is
removed. Object deallocation is not the only lifecycle signal.

### Gravity VM ownership

An Ada Script scriptable object is represented in `ScriptableComponents` by a
native type-erased wrapper containing its stable type identity and detached
serializable state. The live Gravity instance belongs to its script module VM
and is recreated or rebound from that state. VM instances and native pointers
are not serialized into scenes.

## Consequences

- Swift and Ada Script objects share one scene format and stable type registry.
- Editor inspection is driven by exported-field metadata even when no live VM
  instance exists.
- Missing script types can be surfaced without losing their serialized payload.
- Scriptable objects use the capability boundary in
  [ADR-0004](0004-ada-script-world-capabilities.md) and cannot retain the raw
  world or query pointers.
- Object lifecycle testing must cover decode, attach, ready, update, detach,
  destroy, missing types, aliases, and payload round trips.
- High-entity-count behavior belongs in annotated systems rather than one VM
  object callback per entity.
- User interfaces belong in declarative Ada Script views rather than per-frame
  scriptable-object drawing callbacks.

## Rejected alternatives

### Encode a heterogeneous array of base-class instances directly

Rejected because decoding cannot recover concrete subclasses without a stable
type discriminator and registry.

### Serialize every Gravity instance property automatically

Rejected because internal caches, component bindings, closures, and transient
VM state must not become persistent accidentally. Only `@export` fields are
encoded.

### Use scriptable objects as the primary ECS execution model

Rejected because object callbacks and VM instances do not replace chunk-based
query iteration for scalable workloads.

### Draw UI immediately from a scriptable object callback

Rejected because it bypasses AdaUI view identity, retained state, layout,
focus, hit testing, accessibility, native controls, and render invalidation.
