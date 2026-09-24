# Ada Script Annotation Reference

Choose an annotation by the declaration it describes. Annotation arguments
are literals, identifiers, or lists of those values, not runtime expressions.
The same spelling can have different roles: `@component` declares a struct,
while `@component(required: true)` binds an existing component to a scriptable
instance.

## Suspension policy

`@nonsendable` marks a class, struct, or enum whose values must not be captured
by an async task or delivered through an awaited result. A typed async
parameter or async method on a marked type is rejected while compiling;
untyped values are checked when the task is created. AdaEngine marks its
callback-scoped world, query, resource, and input bridge types the same way.
This is a suspension lifetime rule, separate from Swift's `Sendable` protocol.

```ada
@nonsendable
class TemporarySelection {}

// Invalid: the parameter cannot live in an async function.
async func inspect(selection: TemporarySelection) {}
```

## Systems and scheduling

| Annotation | Target | Effect |
| --- | --- | --- |
| `@system(scheduler: "update", id: "...")` | Class | Registers `update(context)` with an ECS scheduler. `scheduler` defaults to `update`; `id` defaults to the class name. |
| `@after(id: "...")` | System class | Runs after another system in the same module and scheduler. Repeatable. |
| `@before(id: "...")` | System class | Runs before another system in the same module and scheduler. Repeatable. |
| `@query(Component, with: Filter, without: Filter)` | Stored system property | Fetches one or more components. `with` and `without` filter without exposing a row field. |
| `@res` or `@res(optional: true)` | Typed system property | Binds an ECS resource during `update(context)`. Optional bindings support `available()`. |
| `@remote_commands(CommandType)` | Stored system property | Exposes received typed network commands. |

Every `@system` class defines `update(context)`, including a startup system.
`@system(scheduler: "startup")` runs when the world's default scheduler runner
first updates. It runs once for that runner's lifetime, before `preUpdate`,
`update`, and `postUpdate`. Restarting the world creates a new startup run.
`startupSystem` in project runtime settings selects an existing startup system
ID and places it first among the module's startup plans. It does not turn an
ordinary update system into a one-time callback.

```ada
@system(scheduler: "startup", id: "game.seed-world")
class SeedWorld {
    func update(context) {
        context.world.spawn([Transform()]);
    }
}
```

There is currently no `@init` function annotation. A class constructor
initializes its script instance when the module loads; it does not receive a
world context. Use a startup system for one-time world setup.

An unknown dependency ID, self-dependency, cross-scheduler dependency, or
cycle is rejected during module validation. Fetched query components reserve
write access conservatively; filter-only components do not. `@access` is
reserved for future explicit access declarations and is not a supported
scheduling override yet. See <doc:AdaScriptECS> for row lifetime and deferred
structural changes.

## Data and attached behavior

| Annotation | Target | Effect |
| --- | --- | --- |
| `@component(id: "...")` | Struct | Declares a component with a stable ID. |
| `@resource(id: "...", autoInsert: true)` | Struct | Declares a resource; `autoInsert` defaults to `false`. |
| `@export` | Stored field | Gives a component or resource field a constant default, or makes a scriptable field persistent and inspectable. |
| `@scriptable(id: "...", version: 1, aliases: ["..."])` | Class | Registers per-entity behavior. `id` is required. |
| `@component(required: true)` | Typed scriptable property | Binds a component from the attached entity. `required` defaults to `false`. |
| `@res(optional: true)` | Typed scriptable property | Binds a resource. `optional` defaults to `false`. |

`@component` and `@resource` structs need at least one `@export` field. Their
fields use constant defaults. `@scriptable` export values are serialized in its
payload, while component and resource bindings are transient. A required
component is checked before `ready(context)`. Attachment calls `ready` once;
detachment calls `destroy` once. `update`, `fixedUpdate`, and `event` have
their own lifecycle callbacks.

```ada
@component(id: "game.health")
struct Health {
    @export var current = 100;
}

@scriptable(id: "game.player")
class Player {
    @export var speed = 8.0;
    @component(required: true) var transform: Transform;

    func ready(context) {}
    func update(context) {}
    func destroy(context) {}
}
```

SwiftPM targets generate native backing types through `AdaScriptBuildPlugin`.
AdaEditor can register supported runtime-defined component layouts in pure
AdaScript projects. A Swift component must be registered before the AdaScript
plugin resolves it. See <doc:AdaScriptLanguage> for more on scriptable objects.

## Multiplayer

| Annotation | Target | Effect |
| --- | --- | --- |
| `@network_command(id: "...", ...)` | Struct | Defines a typed command schema; every field needs `@network_field`. |
| `@rpc(id: "...", ...)` | Function or system method | Defines a typed command from tagged parameters. Write `;` or an empty body; the implementation is generated. |
| `@network_field(tag, mode: "state", interpolate: "none")` | Command or replicated field; RPC parameter | Gives a stable positive UInt16 wire tag. |
| `@replicated_component(id: "...", version: 1, authority: "host", visibility: "all_peers")` | Struct | Declares a replicated component; it already implies component behavior. |
| `@local` | Replicated component field | Keeps a field local rather than assigning it a wire tag. |

`@network_command` and `@rpc` accept `id`, `version`, `direction`, `delivery`,
`channel`, and `maximumPayloadSize`. Defaults are version `1`, direction
`peer_to_host`, delivery `reliable_ordered`, channel `command`, and maximum
payload size `65536` bytes. Directions are `peer_to_host`, `host_to_peer`, and
`bidirectional`; delivery is `reliable_ordered`, `unreliable`, or
`unreliable_sequenced`. `id` is required. Versions and payload limits are
positive integers.

For replicated components, authority is `host` or `any_peer`; supported
visibility is `all_peers`. Network fields accept mode `state`, `latest`, or
`initial_only` and interpolation `none`, `linear`, or `custom`. Wire tags are
unique within a declaration. A replicated field cannot also be `@local`.
`@remote_commands` receives a command; the runtime supplies authenticated
`message.source` separately from payload fields. Install the multiplayer
runtime plugin before registering network declarations.

```ada
@network_command(id: "game.input", delivery: "unreliable_sequenced")
struct PlayerInput {
    @network_field(1) var moveX = 0.0;
}

@system
class InputSystem {
    @remote_commands(PlayerInput) var inputs;

    func update(context) {
        for (var message in inputs) {
            var requestedMovement = message.value.moveX;
        }
    }
}
```

## AdaUI and editor tools

| Annotation | Target | Effect |
| --- | --- | --- |
| `@view(id: "...", title: "...")` | Class or struct | Registers a declarative view with `body()`. Both arguments are optional. |
| `@previewable(title: "...")` | `@view` class or struct | Lists the view in AdaEditor Preview. The optional title overrides the view title. |
| `@state` | Stored view property | Holds view-owned mutable state while the view identity lives. |
| `@environment(key)` | Stored view property | Reads an AdaUI environment value before evaluating `body()`. |
| `@tool(id: "...", ...)` | Class | Declares AdaEditor tool metadata; `id` is required. |

Supported `@environment` keys are `colorScheme`, `isEnabled`, `scaleFactor`,
and `userInterfaceIdiom`. `@binding` for nested script-view parameters is not
implemented and produces a diagnostic. `@previewable` without `@view`, or on
a declaration without `@view`, is invalid. See <doc:AdaScriptViews> for view syntax.

`@tool` accepts optional `name`, `version`, `api`, `platforms`, and
`permissions`. Defaults are a humanized class name, version `1.0.0`, API `1`,
platforms `["macos", "ipados"]`, and no permissions. The version has three
numeric components. Supported permissions are `clipboard.read`,
`clipboard.write`, `editor.documents.read`, `editor.documents.write`,
`workspace.read`, `workspace.write`, `network`, and `process`. A tool class
cannot combine `@tool` with another declaration annotation.

## Common mistakes

- `@query` must annotate a stored property in an `@system` class and fetch at
  least one component. `@with`, `@without`, `@changed`, and `@added` are not
  standalone annotations.
- System and scriptable `@res` bindings use `var name: Type;`. A scriptable
  `@component` binding uses the same typed property form.
- `@remote_commands` uses exactly one positional command type and an untyped
  `var name;` property.
- A class constructor, `ready(context)`, and a startup system have different
  lifetimes. Use the callback that matches the data being initialized.
- Borrowed contexts and component views expire after their callback.
