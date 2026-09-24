# ADR-0006: Build Ada Script UI on the native AdaUI graph

- Status: Superseded by [ADR-0016](0016-temporarily-disable-adascript-adaui.md)
- Date: 2026-08-31
- Implementation: Partial (foundation shipped)

## Context

Ada Script gameplay code needs to create heads-up displays, menus, overlays,
forms, and reusable interface components. AdaUI is already a retained,
declarative UI system with identity-based state, environment propagation,
layout, native view hosting, focus, input routing, hit testing, accessibility,
render invalidation, and render-world extraction.

An immediate-mode script canvas or a per-frame `drawGUI` callback would create a
second UI runtime and bypass these behaviors. Directly exposing native
`ViewNode` or `UIView` objects would also let Gravity retain main-actor objects
with lifetimes that the VM cannot safely manage.

AdaUI view bodies may be reevaluated in response to state, bindings,
environment, focus, input, or layout-related invalidation. That reevaluation is
not necessarily inside an ECS scheduler scope. Script views therefore cannot
retain component or resource pointers obtained by an ECS system.

## Decision

### Optional integration target

The integration is owned by a dedicated `AdaScriptingUI` target that depends on
`AdaScripting` and `AdaUI`. Core Ada scripting does not acquire AdaUI's rendering,
text, input, and platform dependencies.

`AdaScripting` exposes annotation and bridge registration extension points.
`AdaScriptingUI` provides:

- the `AdaUI` virtual import module;
- `@view`, `@state`, `@binding`, `@environment`, and UI snapshot semantics;
- factories for supported AdaUI primitives and modifiers;
- the script view host and reconciliation node;
- mounting through `UIComponent` and world UI commands;
- AdaUI-specific LSP metadata and diagnostics.

The high-level AdaEngine product may re-export the integration, while packages
that use only ECS scripting can omit it.

### View declarations

A reusable script view is declared with `@view`:

```ada
import {
    VStack,
    Text,
    Button,
    TextField
} from "AdaUI";

@view(id: "game.hud")
class GameHUD {
    @state
    var isPaused = false;

    @state
    var playerName = "Player";

    @environment
    var colorScheme: ColorScheme;

    @snapshot(resource: GameHUDState)
    var game;

    @eventWriter
    var actions: GameUIAction;

    func body() {
        return VStack([
            Text("Health: \(game.health)"),
            TextField(
                "Name",
                text: bind(playerName)
            ),
            Button(
                isPaused ? "Resume" : "Pause",
                action: func() {
                    isPaused = !isPaused;
                    actions.send(
                        GameUIAction.pauseChanged(isPaused)
                    );
                }
            )
        ])
        .padding(16.0)
        .accessibilityIdentifier("game.hud");
    }
}
```

The initial child-building syntax uses ordinary Gravity lists. Ada Script does
not add a second trailing-closure or result-builder grammar solely for UI. A
future syntax improvement may lower to the same view-description model without
changing runtime semantics.

`body()` returns a script view description. It does not return, own, or retain a
native `ViewNode`.

### Native AdaUI construction and reconciliation

`AdaScriptingUI` converts a script view description into native AdaUI views and
modifiers through a registered factory table. The resulting subtree is hosted
by a native `ScriptViewNode` and participates in the existing AdaUI paths for:

- layout and placement;
- render recording and dirty-region invalidation;
- input delivery and hit testing;
- focus and text input;
- environment propagation;
- accessibility identifiers and inspection;
- native platform representables registered by Swift.

The VM is not called during native draw, layout, or hit testing. Gravity is
entered only to evaluate an invalidated `body()` or invoke a script event
closure. This avoids a VM call per node per frame.

Reconciliation compares primitive kind, explicit identity, and structural
position. Compatible native nodes are updated in place. Replacing a primitive
kind or identity replaces its subtree using ordinary AdaUI semantics.

### State and identity

`@state` is main-actor runtime state owned by the corresponding native script
view state container. Its storage identity includes:

- the script module and stable `@view` identifier;
- the structural or explicit node identity path;
- the state property name;
- the state value schema.

State is preserved across body reevaluation and compatible hot reload. Changing
the view identifier, state property name, or state schema resets the affected
state with a diagnostic in development builds.

`@state` is transient and is not scene-coded. Persistent configuration uses
explicit exported inputs or an application model. A future `@sceneStorage`
facility requires a separate decision.

Lists whose order may change must provide stable identities through the AdaUI
equivalent of `id`. Relying on list position may reset state when items move.

### Bindings

`bind(value)` is compiler-recognized syntax that accepts an assignable
`@state` or `@binding` property and creates a native AdaUI `Binding` adapter.

```ada
TextField("Name", text: bind(playerName))
Toggle("Paused", isOn: bind(isPaused))
```

The adapter reads and writes the owning main-actor state storage. A binding is
valid only inside the mounted view graph and cannot be retained in a global,
component, resource, or command payload.

Child views receive parent-owned values through `@binding`. Immutable constructor
inputs remain detached values.

### Environment

`@environment` exposes registered, platform-neutral AdaUI environment values
such as color scheme, scale, safe-area insets, enabled state, locale, and theme.
It does not expose the raw `World`, `Entity`, input manager, window manager, or
native platform view objects even when such values exist in native
`EnvironmentValues`.

Changes to an environment value invalidate only views subscribed to that key,
following native AdaUI environment behavior.

### ECS data snapshots

`@query`, `@component`, and direct `@res` bindings are invalid on `@view` types.
They would expose pointers whose scheduler lifetime can end before a later view
reevaluation or input callback.

UI reads gameplay data through detached snapshots:

```ada
@snapshot(resource: GameHUDState)
var game;
```

A dedicated native UI snapshot system reads declared ECS resources during a
scheduler scope, converts them to detached Ada Script values, and publishes a
new immutable snapshot on the main actor. A changed snapshot invalidates only
subscribed views.

The initial implementation supports resource snapshots. Entity/component query
snapshots require an explicit projection declaration that produces detached,
bounded data; a view cannot request an unbounded live ECS query.

UI writes gameplay state by sending events or deferred commands through declared
capabilities. It never writes an ECS resource or component pointer directly.

### Events and actions

Native AdaUI controls retain closures that call back into the owning script
module on the main actor under the serialized Gravity runtime boundary.
Callbacks may:

- mutate local `@state`;
- write through a valid `@binding`;
- send a declared event;
- enqueue a detached world command;
- request navigation, presentation, or dismissal through the UI capability.

Callbacks must not start a live ECS query or retain callback context objects.
Reentrant view invalidation is coalesced and reconciled after the callback
returns.

### Mounting

Reusable views are not mounted merely because they are declared. They may be
mounted explicitly through deferred world/UI commands:

```ada
context.world.commands.mountUI(
    GameHUD(),
    behaviour: "overlay",
    window: "primary"
);
```

Mounting creates the native host represented by AdaUI's `UIComponent` and
installs it through the existing UI system. Dismissal is also deferred.

A declarative application root may opt into automatic mounting:

```ada
@view(id: "game.main-menu")
@uiRoot(
    window: "primary",
    behaviour: "overlay"
)
class MainMenu {
    func body() {
        return Text("AdaEngine");
    }
}
```

Duplicate root identifiers or incompatible window declarations are setup
diagnostics.

### Coding and hot reload

The scene representation of a mounted script view stores its stable view type
identifier and exported configuration. It does not encode local `@state`, event
closures, bindings, environment values, snapshots, VM handles, or native nodes.

Hot reload recompiles the affected script module and recreates its view
description factory. Compatible host, node, and state identities are retained.
Event closures are rebound to the new module generation. If reload fails, the
currently mounted native subtree remains active and the diagnostic is surfaced
without replacing it with an empty view.

### Initial surface

The first supported Ada Script UI surface includes native AdaUI primitives and
modifiers needed for ordinary HUD and form construction:

- text, image, button, text field, toggle, spacer, and progress presentation;
- vertical, horizontal, overlay, scroll, and lazy stack containers;
- padding, frame, background, foreground, opacity, visibility, disabled state,
  identity, accessibility identifier, and basic animation;
- tap, press, drag, keyboard, focus, and text-input behaviors already supported
  by their native nodes.

Swift may register additional script-facing views and modifiers through an
explicit bridge descriptor. Arbitrary AppKit, UIKit, SwiftUI, or native
representable construction is not exposed directly to Gravity.

## Consequences

- Ada Script UI uses the same retained view graph, state invalidation, layout,
  input, focus, accessibility, and render extraction as Swift AdaUI.
- UI scripting remains optional for packages that need only ECS scripting.
- View body evaluation and callbacks are main-actor operations and serialize
  entry into the non-reentrant Gravity runtime.
- ECS snapshots add an explicit frame boundary between simulation data and UI
  rendering, avoiding pointers that outlive scheduler access.
- The Editor and LSP must understand `@view`, state/binding ownership,
  environment keys, supported primitives, modifiers, imports, and callback
  signatures.
- Runtime validation must use a real `UIContainerView` or `UIComponent` and
  exercise state persistence, layout, hit testing, focus, text input, events,
  accessibility, reconciliation, and hot reload. Source-text or manifest tests
  alone are insufficient.

## Rejected alternatives

### Immediate-mode `drawGUI`

Rejected because it creates a parallel UI model and bypasses AdaUI identity,
state, layout, focus, hit testing, accessibility, and invalidation.

### Return native `ViewNode` or `UIView` objects to Gravity

Rejected because native main-actor objects and their lifetimes must remain owned
by AdaUI rather than the VM.

### Evaluate Gravity during every draw or layout operation

Rejected because it adds VM overhead to native hot paths and makes rendering
dependent on script reentrancy.

### Allow live ECS queries and resource pointers in a view body

Rejected because body evaluation and input callbacks can occur after the ECS
scheduler scope that granted pointer access.

### Make core AdaScripting depend directly on AdaUI

Rejected because UI scripting would impose rendering, text, input, and platform
dependencies on every scripting consumer.
