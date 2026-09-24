# UI scenes

Create a **UI Scene** from the project browser's **New** menu. `.ui` files contain
versioned YAML and open in a dedicated designer. They are reusable AdaUI resources,
not entity scenes.

The palette inserts into the selected container. Compose with HStack, VStack,
ZStack, Grid and lazy stacks; use ScrollView around overflowing content. Drag a
hierarchy row vertically to reorder it, or drag right onto another row to nest it.
The inspector edits properties, bindings, actions and ordered modifiers. Select
**Add content from palette** on a background/overlay modifier to fill its content
slot. **Design** selects nodes; **Interact** runs the controls against preview data.
**YAML** exposes the source, including diagnostics for unresolved exports.

The root inspector declares inputs with types and preview defaults, and named
actions. Property **Value / Binding** switches between a literal and a data path.
If reads a boolean binding; ForEach reads an array and a stable `idKey`, exposing
its current object as `item`. View state survives reordering by ID. A UI node
includes another `.ui`, with explicit input and action mappings. Open that source
with **Open UI source**. Include cycles are errors.

## Runtime

```swift
let data = UIBindingContext(values: ["playerName": .string("Ada")])
data.on("startGame") { arguments in /* start the game */ }
let component = try UIComponent(
    ui: "HUD.ui", context: data, behaviour: .overlay,
    resourceRoot: assetsDirectory
)
```

`data.bind("playerName", to: ...)` connects a `Binding<UIValue>` to existing game
state. Contexts are main-actor isolated. Factories receive detached values,
bindings and scoped actions; they must not access a VM or mutate the ECS world
while constructing a View. Custom control event callbacks use `inputs.perform`.

## Bind a designed Text to a gameplay script

1. In the UI Editor, declare a string input `title` under **Inputs & actions**,
   with a preview default such as `Hello`.
2. Select the Text, switch its `text` property to **Binding**, and select/type `title`.
3. In the entity scene, attach the gameplay script and a **UI Component** to the
   same entity. Choose the `.ui` file as the component source.
4. Under **Script field bindings**, press **+ Binding**. Choose the UI input,
   the attached script's identifier, and its exported field. Leave **Data context** empty.
5. Save the entity scene and press Play. The UI Editor uses preview defaults;
   gameplay fields are evaluated in Play mode.

For example, attach this AdaScript:

```adascript
@scriptable(id: "game.hud")
class HUD {
    @export var title = "Hello";

    func ready(context) {
        title = "Game started";
    }

    // Assign title from update, event, or other gameplay code as needed.
}
```

The mapping is stored in the `.ascn` UI component, so it survives reopening the
project. Only exported fields of scripts on the same entity are eligible. UI
input and field types must agree: for a Text's `text`, export a string (format
numeric scores in game code). Object inputs also support paths such as `player.name`.

The equivalent runtime setup is:

```swift
let ui = UIComponent(source: .init(
    path: "@res://HUD.ui",
    scriptBindings: ["title": .init(script: "game.hud", field: "title")]
))
// Attach ui and the registered game.hud script to the same entity.
// DefaultPlugins includes ScriptableObjectPlugin; custom hosts must add it.
```

After script updates, `ScriptUIBindingSystem` publishes detached values into the
component's context. AdaUI refreshes when those values change. TextField/TextEditor
edits queue a write back to the exported field on the next synchronization pass;
view construction never calls the script VM. Replacing the script discards pending
edits for the old instance. Missing scripts, unavailable fields and rejected writes
are recorded in `ui.scriptBindingContext?.diagnostics`. The inspector also flags
missing inputs/fields and incompatible scalar types.

Swift game models can continue using `UIBindingContext.bind` directly. Native
`ScriptableObject` subclasses using the same entity mapping implement
`readExportedField(_:)` and `writeExportedField(_:value:)`, and register their field
metadata. AdaScript supplies these accessors automatically for `@export` fields.

See [BoundLabel.ui](../../Documentation/Examples/UIScenes/Assets/BoundLabel.ui)
and [HUD.ada](../../Documentation/Examples/UIScenes/Scripts/HUD.ada) for a minimal pair.

## Connect a UI Scene to a game

In an entity inspector, add **UI Component**, choose the `.ui` source, and
configure inputs. `.ascn` stores this reference. For code that decodes entities
outside the editor, insert a
`UIComponentRuntimeResource(UIComponentRuntime(resourceRoot: assetsDirectory))`
into the world before updating UI. Named game contexts are registered in
`runtime.contexts`; arbitrary Swift View instances and closures are not Codable.

Resource paths accept `@res://` (relative to the resource root), or paths relative
to the including `.ui`. Resources must stay inside that root. File watchers can
send `UISceneResourceChanged` through the view's event manager. Invalid updates
retain the last working tree and expose a diagnostic on the session.

## Explicit exports

Swift modules implement `UIExportProvider`, returning `UINativeViewDescriptor`
and `UINativeModifierDescriptor` values. Signatures declare stable IDs, versions,
parameter types, bindings, actions and content slots. Register the same descriptors
in the game's UICatalog. The editor reads `.ada/ui-exports.json`, builds native
providers using the existing Swift Preview builder, and verifies their compiled
signatures before activating them. Keep export providers outside executable entry
point files.

Swift factories must be compiled into the host on iPadOS. Desktop SwiftPM
projects can build their exports locally; portable AdaScript projects cannot
compile arbitrary Swift sources on iPadOS.

See [the inventory example](../../Documentation/Examples/UIScenes) for Grid,
ForEach, a nested ItemCard.ui and an explicitly exported Swift badge. The example
is a SwiftPM library that can be opened in the editor or linked into a game.
