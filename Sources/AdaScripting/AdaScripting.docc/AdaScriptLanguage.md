# Ada Script Language

Use Ada Script syntax with AdaEngine declaration annotations. New to the
language? Start with <doc:AdaScriptBasics> for values, functions, types,
properties, control flow, asynchronous work, and annotations.

## Source files

Ada Script uses `.ada` files. A file contains classes,
functions, variables, and control flow. Ada Script modules do not declare a
`main()` function and do not assemble plugin manifests.

```ada
@system(scheduler: "update")
class CounterSystem {
    @query(Counter)
    var counters;

    func update(context) {
        for (var entity in counters) {
            entity.counter.value += 1;
        }
    }
}
```

## Optional strict type checking

Ada Script remains dynamically typed by default. Enable strict checking for a
single source by placing `@strict` before its first declaration:

```ada
@strict

func addScore(score: Int, amount: Int) -> Int {
    return score + amount;
}
```

In an AdaEditor project, **Project Settings → Runtime → Type Checking → Strict**
enables the same analysis for every `.ada` source. The serialized setting is:

```json
{
  "build": {
    "system": "adascript",
    "adaScriptTypeChecking": "strict"
  }
}
```

Strict checking validates annotated assignments, function arguments, member
access, and return values before the module runs. Use `Any` for an intentional
dynamic boundary. Untyped code and projects using `"dynamic"` keep normal
Ada Script runtime behavior.

## Imports

Files with discovery annotations such as `@system` are module roots. Import a
helper declaration explicitly from another target-relative source file:

```ada
import {
    clampSpeed,
    MovementSettings
} from "../Shared/Movement";
```

Relative imports are resolved from the importing file. The `.ada` extension is
optional. Absolute paths and imports which escape the Swift target source map
are rejected. A reachable source is compiled once, and an import cycle reports
the complete cycle.

The current implementation supports selected relative imports. Namespace
imports, public/private visibility enforcement, and the `AdaEngine` / `AdaUI`
virtual-module declarations remain part of the next module-language slice.

## Annotations

Ada Script declaration annotations have three forms:

```ada
@name
@name(value)
@name(key: value, other: [a, b])
```

Arguments are compile-time constants or symbolic identifiers. They do not run
user code during module discovery.

See <doc:AdaScriptAnnotations> for supported annotations, declaration targets,
arguments, defaults, and lifetimes. A one-time world initializer is a
`@system(scheduler: "startup")` class with `update(context)`; there is no
function-level `@init` annotation yet.

## Script-defined data

The build plugin generates native backing types for scalar component and
resource schemas:

```ada
@component(id: "game.health")
struct Health {
    @export var current = 100.0;
    @export var maximum = 120;
}

@resource(id: "game.balance", autoInsert: true)
struct GameBalance {
    @export var acceleration = 9.8;
}
```

Generated Swift symbol names are private implementation details. Runtime lookup
accepts both the Ada Script declaration name (`Health`) and the stable ID
(`game.health`). `autoInsert: true` inserts the resource before systems are
installed. SwiftPM targets use generated backing types; AdaEditor can register
supported runtime-defined component layouts for pure AdaScript projects.

Bind a resource directly on a system with `@res`. The binding uses a native ECS
resource pointer during `update(context)`; field writes update the resource
change tick:

```ada
@system(id: "physics.system")
class PhysicsSystem {
    @res
    var balance: GameBalance;

    func update(context) {
        balance.acceleration += 0.1;
    }
}
```

A missing required resource is reported through plugin diagnostics. Optional
resources can be guarded with `available()`:

```ada
@res(optional: true)
var debugSettings: DebugSettings;

if (debugSettings.available()) {
    debugSettings.enabled = true;
}
```

Resource access is currently conservative: each `@res` requests scheduler write
access. Static read/write inference and explicit access overrides are planned.

## World commands

Systems receive a capability-scoped world facade. Structural changes are
queued through `context.world.commands` and applied only after the current
system parameters finish, so an active query iterator cannot be invalidated:

```ada
@system(id: "cleanup.system")
class CleanupSystem {
    @query(Expired)
    var expired;

    func update(context) {
        for (var entity in expired) {
            context.world.commands.despawn(entity.id);
        }
    }
}
```

The initial command API creates registered component defaults by Ada Script name
or stable ID:

```ada
var entity = context.world.commands.spawn(["game.health"]);
context.world.commands.insert(entity, "game.poison");
context.world.commands.remove(entity, "game.poison");
context.world.commands.despawn(entity);
```

Direct command use is inferred per system and declares deferred-world access to
the scheduler. Command facades expire when `update(context)` returns; using a
retained or undeclared facade reports a plugin diagnostic and performs no
mutation. Typed component constructors can be passed to
`context.world.spawn([...])`; the legacy string-based command form remains
available. Explicit dynamic `@access` and exclusive immediate world access
are not implemented.

SwiftPM generation of native backing types requires `AdaScriptBuildPlugin`;
supported pure AdaScript layouts can be registered by the runtime.

Swift and Editor tooling can attach the generated default without naming its
private backing type:

```swift
world.insertDefaultComponent(named: "game.health", into: entity.id)
```

Field types and serialization support vary by schema and bridge. Check the
nearest compiler diagnostic when a constructor argument or field default is
unsupported.

## Scriptable objects

Use `@scriptable` for low-cardinality behavior attached to one entity. Systems
remain the scalable path for processing large entity sets.

```ada
@scriptable(
    id: "game.player-controller",
    version: 2,
    aliases: ["PlayerController"]
)
class PlayerController {
    @export var speed = 8.0;
    @component(required: true) var transform: Transform;
    @res(optional: true) var settings: PlayerSettings;

    func ready(context) {}

    func update(context) {
        transform.position += speed * context.deltaTime;
    }

    func fixedUpdate(context) {}
    func event(events, context) {}
    func destroy(context) {}
}
```

The build plugin registers stable IDs, versions, aliases, exported scalar
defaults, and transient component/resource bindings. Required components are
checked before `ready`. Optional resources expose `available()`.

`ScriptableComponents` encodes a polymorphic envelope containing only `type`,
`version`, and detached `payload`. Entity bindings, resources, VM instances,
world contexts, and lifecycle state are never serialized. Decoding does not run
gameplay; attachment runs `ready` once and detachment runs `destroy` once.

Scriptable contexts expose the same expiring deferred commands facade as
systems. Retaining it after a callback produces a diagnostic. Scriptable
objects intentionally have no immediate-mode GUI callback; declarative UI
belongs to AdaUI script views.

## Multiplayer schemas

Use a typed command for peer intent. Field tags, rather than declaration order
or source names, define the wire schema:

```ada
@network_command(
    id: "game.player-input",
    delivery: "unreliable_sequenced",
    channel: "input"
)
struct PlayerInput {
    @network_field(1) var moveX = 0.0;
    @network_field(2) var moveY = 0.0;
    @network_field(3) var attackSequence = 0;
}
```

Peers send the generated value through the scoped multiplayer resource. Host
systems receive typed values and an authenticated transport source:

```ada
@system
class InputSystem {
    @res var multiplayer: Multiplayer;
    @remote_commands(PlayerInput) var inputs;

    func update(context) {
        multiplayer.send(PlayerInput(1.0, 0.0, 4));
        for (var message in inputs) {
            var peer = message.source;
            var movement = message.value.moveX;
        }
    }
}
```

The runtime owns packet sequences and command envelopes. `message.source`
cannot be supplied by script payload data. Swift and AdaScript declarations
with matching IDs, versions, tags, types, direction, delivery, and channel
produce the same compatibility schema.

`@replicated_component` uses `@network_field` plus optional `@local` fields.
SwiftPM targets receive a generated native ECS backing component through
`AdaScriptBuildPlugin`. Portable AdaEditor projects register each component as
a distinct runtime ECS layout without compiling Swift.

`@rpc` declares both a typed wire command and an optional receiver method:

```ada
@system class InputSystem {
    @res var multiplayer: Multiplayer;
    @res var playerInput: PlayerInputState;

    @rpc(id: "arena.input", delivery: "unreliable_sequenced", channel: "input")
    func input(@network_field(1) moveX = 0.0, @network_field(2) attack = 0) {
        playerInput.peer = source;
        playerInput.moveX = moveX;
        playerInput.attack = attack;
    }

    func update(context) {
        multiplayer.send(input(1.0, 2));
    }
}
```

Calling `input(...)` constructs a typed command; `multiplayer.send(...)` sends
it. The authored body does not run on the sender. On receipt, the system invokes
it before `update`, with `source` bound to the authenticated transport peer ID.
Fields remain tagged and require constant defaults. An empty or bodyless method
still works as a command constructor; `@remote_commands(input)` remains available
for explicit message processing. Request/response and local echo are not yet
supported.

## AdaUI views

Use `@view` on a class or struct whose `body()` contains declarative AdaUI expressions.
Add `@previewable` when that view should appear in AdaEditor Preview. See
<doc:AdaScriptViews> for the supported view constructors, modifiers, and
preview workflow.

## Asynchronous work

Declare a function that can suspend with `async func`. Use `await` inside that
function; a synchronous action starts it explicitly with `Tasks.start(...)`.
The action returns immediately while the game or UI continues updating.

```ada
async func loadShop() {
    var result = await Assets.loadAsync("@res://Catalog/shop.json");
    if (result.isSuccess()) {
        System.print("Shop asset: " + result.value());
    } else {
        System.print(result.errorCode() + ": " + result.message());
    }
}

@system class ShopSystem {
    var started = false;

    func update(context) {
        if (!started) {
            started = true;
            Tasks.start(loadShop());
        }
    }
}
```

`Assets.loadAsync` and `Assets.saveAsync` use the native asset registry and
return an awaitable result. `Saves.writeAsync("@user://save.txt", text)` writes
an immutable string in the background and reports `committed()` after its
atomic file replacement. For data that cannot be copied in one callback, use
bounded chunks:

```ada
async func saveLargeData() {
    var writer = Saves.begin("@user://save.txt");
    var first = await writer.appendAsync("first chunk");
    if (!first.isSuccess()) { writer.cancel(); return; }
    var committed = await writer.finishAsync();
    if (!committed.committed()) { System.print(committed.message()); }
}
```

Each chunk is limited to 256 KiB. The writer appends to a temporary file and
replaces the destination only after `finishAsync()` succeeds. Build large ECS
snapshots in bounded pieces; do not retain a query row or live component view
in a task.

Mark a script-owned type with `@nonsendable` when its instances are tied to a
callback or another short lifetime. AdaScript rejects a typed async parameter
or method that would capture that type. Before a task starts, the runtime also
checks actual arguments, nested lists, returned values, and promise results;
this catches borrowed engine values passed through an untyped alias. Maps are
conservatively rejected until their entries can be inspected. See
<doc:AdaScriptAnnotations>.

`await Time.sleep(seconds)` advances with the scheduler's `deltaTime` and stops
advancing when that scheduler is paused. AdaEngine does not yet expose a
separate game time-scale resource.
`await Time.sleepRealTime(seconds)` uses a monotonic clock; continuation still
waits for a script dispatch point. `Tasks.promise()` creates a one-shot wait
that an action can resolve with `complete(value)`. A Boolean `false` from a
confirmation is a user choice; closing its view cancels the waiting task.
`Tasks.start(...)` returns a handle with `status()` and `cancel()`.

AdaScript callbacks such as `update(context)`, `body()`, and UI actions remain
synchronous. Do not mark them `async`; start a separate async function and pass
detached values. Callback contexts, queries, resources, and commands expire at
callback exit. Awaited work resumes in the serialized script runtime, not on
the native I/O worker. A task started by a view is cancelled when that view
is disposed or its module is replaced. Cancelling a save does not roll back
a file that was already committed.

Fallible operations return a result with `isSuccess()`, `value()`,
`errorCode()`, and `message()`; inspect it after `await`. A script VM trap
currently stops that module and cancels its pending tasks. Diagnostics include
the failing task, owner, and trace ID; reload the module to continue. Other
module instances and native gameplay remain separate.

## System context

`update(context)` receives a scoped system context. `context.deltaTime` is the
current scheduler delta. Context and query values must not be retained after
the callback.

## State

Fields on a system instance persist between scheduler updates:

```ada
@system(scheduler: "update")
class LifetimeSystem {
    var elapsed = 0.0;

    func update(context) {
        elapsed += context.deltaTime;
    }
}
```

Use local variables for per-call calculations. Store ECS gameplay state in
components and shared singleton state in resources rather than global mutable
variables.

## Common language patterns

The syntax primer in <doc:AdaScriptBasics> covers functions, conditions,
loops, structs, classes, static members, initializers, and accessors. In an ECS
system, use those language features together with query bindings:

```ada
func clampHealth(value, maximum) {
    if (value < 0) { return 0; }
    if (value > maximum) { return maximum; }
    return value;
}

@system
class DamageSystem {
    @query(Health, without: Invulnerable)
    var targets;

    func update(context) {
        for (var target in targets) {
            target.health.current = clampHealth(target.health.current - 1, 100);
        }
    }
}
```

Functions called by a system are ordinary helpers; they do not become
scheduler callbacks. A system's `update(context)` is the entry point selected
by `@system`. A scriptable object's `ready(context)` instead belongs to that
entity's attachment lifecycle. For one-time world setup, use the `startup`
scheduler described in <doc:AdaScriptAnnotations>.

An `import { name } from "./Helpers";` brings a helper into the target-level
module. Importing a file does not create a second world or a second run of its
systems. A library can contribute its own annotated declarations; keep IDs
unique across the assembled module. See <doc:AdaScriptLibraries>.

## Values crossing the bridge

Ada Script bridge values are detached booleans, integers, finite floating-point
numbers, strings, lists, and null. ECS component views are borrowed native
capabilities rather than detached values.

Unsupported values and invalid numeric conversions are rejected without
partially mutating a component.

System `update(context)` callbacks are command-style. Their return values are
ignored; observable behavior belongs in components, resources, events, or
diagnostics.
