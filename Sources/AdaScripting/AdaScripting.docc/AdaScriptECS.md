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

Positional components are fetched and available on each row. Four more clauses
take one component or a list:

| Clause | Meaning |
| --- | --- |
| `optional: Target` | Fetched like a positional component, but rows may lack it. `entity.target` is `null` when absent. |
| `with: Movable` | The entity must have it; it is not fetched. |
| `without: Frozen` | The entity must not have it. |
| `changed: Health` | Rows where any listed component changed since the system last ran. |
| `added: Marker` | Rows where any listed component was added since the system last ran. |

```ada
@query(Health, Movement, optional: Target, with: Movable, without: Frozen, changed: Health)
var entities;

for (var entity in entities) {
    if (entity.target != null) { entity.health.current -= entity.target.damage; }
}
```

`changed` and `added` need the component to exist in the archetype; the change tick
of a component is updated by every successful field write. A boolean `where:` clause
and any other label are rejected with a message naming the supported clauses.

Row properties are the lower-camel-case component names, or an explicit alias
written with `as`. A component may be named by its qualified path:

```ada
@query(Game.Health as hp, Physics.Movement as motion)
var entities;

for (var entity in entities) {
    var position = entity.motion.position;
    entity.hp.current -= 1.0;
}
```

Two fetched components with the same short name (`Game.Health` and `Physics.Health`)
are an error until one is given an alias, and no component may be aliased `id`.

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

The compiler reads how a system uses its rows and requests exactly that access
from the scheduler:

```ada
var current = entity.health.current;   // read Health
entity.health.current = current - 1;   // write Health
entity.health.current -= 1;            // read and write Health
```

A component that is only read can be shared with other readers; a write reserves
it exclusively. `changed:` and `added:` read a component's ticks, so they request
read access even for a component that is not fetched. Filter-only components
(`with`, `without`) request none.

Analysis follows `for (var row in query)` loops. If a row, a component view, or the
query itself escapes into code the compiler cannot follow (passed to a function,
stored, called with an unknown method), the system must declare what it touches:

```ada
@system(id: "game.inspect")
@access(read: [Health], write: [Transform])
class InspectSystem {
    @query(Health, Transform)
    var entities;

    func update(context) {
        for (var entity in entities) { inspect(entity); }
    }
}
```

Without `@access` this fails to compile, naming the query and component. A
declaration may be broader than the code but not narrower: declaring a component
read-only while the script writes it is an error. The same `@access` declaration
governs the dynamic `context.world.read/write` calls. A precompiled module has no
script text to analyse and keeps write access to every fetched component.

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

### Input keyboard bindings

To bind Space to jumping, open **Project Settings → Input Bindings**, select
or add the `Jump` action, and add a keyboard binding for Space. Save the project
settings, then start Play and press Space. The script checks `Jump` through
the Input resource, so you can change the bound key without editing the script.
