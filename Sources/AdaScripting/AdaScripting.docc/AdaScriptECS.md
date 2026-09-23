# Ada Script ECS

Declare annotation-driven systems and iterate native AdaECS component columns.

## Declare a system

Apply `@system` to a class and implement `update(context)`:

```ada
@system(scheduler: "update", id: "game.movement")
class MovementSystem {
    func update(context) {
    }
}
```

The scheduler defaults to `update`. System identifiers must be unique within a
script module.

For one-time world setup, use `@system(scheduler: "startup")`. Its
`update(context)` runs on the default scheduler runner's first update, before
the regular frame stages. A script class constructor does not receive a world
context. See <doc:AdaScriptAnnotations> for all annotation arguments.

## Order systems

Use repeatable `@after` and `@before` annotations when component and resource
access alone does not express the required execution order:

```ada
@after(id: "game.input")
@before(id: "game.physics")
@system(scheduler: "update", id: "game.movement")
class MovementSystem {
    func update(context) {
    }
}
```

Dependency IDs resolve within the same AdaScript module. Both systems must use
the same scheduler. AdaScript rejects unknown IDs, self-dependencies, and
dependency cycles while loading the module.

## Declare a query

Apply `@query` to a stored system property:

```ada
@query(
    Health,
    Movement,
    with: Movable,
    without: Frozen
)
var entities;
```

Positional components are fetched and available on each row. `with` and
`without` only filter matching archetypes.

Aliases use lower-camel-case component names:

```ada
for (var entity in entities) {
    var position = entity.movement.position;
    entity.health.current -= 1.0;
}
```

`entity.id` exposes the native entity identifier.

## Iterator behavior

Ada Script queries are native iterators. AdaECS resolves matching archetypes,
binds component columns when entering a chunk, and advances their pointers by
row stride. The bridge does not create an entity proxy for every result and
does not perform a world component lookup for every field access.

A query row and its component views are borrowed. Do not retain them after the
loop or system update returns. Structural changes must use deferred commands.

Inactive entities are skipped. Empty queries execute zero loop iterations.

## Component fields

The `@Component` Swift macro generates the runtime field accessors used by Ada
Script. Register native components before the script plugin is set up.

Supported field values include booleans, integers, finite floating-point
values, strings, vectors, quaternions, colors, and reflected enums. A rejected
write leaves the component unchanged and appends a development diagnostic.

## Access planning

The current implementation conservatively declares write access for fetched
components. This keeps scheduling correct while compiler-level read/write
inference is completed. Filter-only components do not receive write access.

The intended final behavior derives read and write sets from row field usage,
with explicit `@access` metadata as the escape hatch for dynamic code.

## Multiple queries

One system may declare multiple independent iterators:

```ada
@system(scheduler: "update")
class TargetingSystem {
    @query(Player, Transform)
    var players;

    @query(Enemy, Target, without: Dead)
    var enemies;

    func update(context) {
        for (var enemy in enemies) {
            for (var player in players) {
                enemy.target.entity = player.id;
                break;
            }
        }
    }
}
```

Queries are refreshed by the scheduler before each system execution.

## Project input actions

In **Project Settings → Input Bindings**, add an action such as `Jump`, then add
keyboard, mouse, gamepad or touch bindings. Click **Save Project Settings**.
Actions are stored in `.ada/project.json` and loaded by both Play Mode and the
AdaScript project runtime. Multiple bindings act as alternatives: releasing one
input does not release the action while another binding is held.

Systems and scriptable components declare input as a read-only resource dependency
with `@res var input: Input;`. Only declarations that request Input receive it.
Use `@res(optional: true) var input: Input;` and `input.available()` when the
resource may be absent; a missing required resource produces a diagnostic.

```adascript
@res var input: Input;

func update(context) {
    if (input.isActionJustPressed("Jump")) {
        // Start a jump once per press.
    }
    var movement = input.getActionStrength("MoveRight");
}
```

- `isActionPressed(name)` remains true while an input is held.
- `isActionJustPressed(name)` and `isActionJustReleased(name)` describe transitions
  during the current frame. Both can be true for a tap completed within one frame.
- `getActionStrength(name)` returns 0...1. Gamepad axes use a direction and the
  action's dead zone; buttons and touch return either zero or one.
- Gamepad bindings match any connected controller. `Any Finger Held` stays active
  until every contact ends or is cancelled. Touch lifecycle events, mouse motion,
  and wheel bindings produce frame pulses.

Input snapshots are scoped to a callback; query input again on the next update.
Unknown action names return false or zero. Names are case-sensitive.

Swift systems use the same methods on their `Input` resource. `InputPlugin()`
loads the `inputActions` section from `.ada/project.json` in the current working
directory, including games launched from the editor. Packaged Swift applications
can decode `[InputAction]` from an included resource and pass it to
`InputPlugin(actions:)`, or call `try input.setInputActions(actions)` on an existing
resource. Explicit `InputPlugin(actions: [])` disables automatic project loading.
