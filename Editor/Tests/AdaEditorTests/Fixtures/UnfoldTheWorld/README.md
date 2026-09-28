# Unfold the world

An experimental Foldable Preview demo for AdaEditor. One scene keeps running as a second display region reveals an interactive mission map.

## Play in AdaEditor

1. Open this folder as a project. Open `Assets/Scenes/Main.ascn`.
2. Click the scene's **Play** control.
3. Choose **Display → Foldable Preview**, then **Expanded**.
4. Tap the orange airlock on the map. The gate slides away and the drone continues to the dock.
5. Switch to **Compact**, then **Expanded**. The gate and drone retain their state. Stop/Play starts a new run.

**Fit** fits the neutral profile to the editor viewport; **1:1** displays its logical point dimensions. The example profile is 400 × 640 compact or 820 × 640 expanded, with a 20-point excluded gap. It is not a specification of an Apple device.

## Scene and UI

The Airlock entity has a `CompanionPanel` referring to `@res://UI/Map.ui`. Its persisted `scriptBindings` map UI inputs to the `unfold.gate` script's exported fields. `ToggleButton` binds `isOn` to `gateOpen`; it queues a change through the existing UI bindings system. The game loop applies the change, moves the gate, and publishes new UI snapshots. The Drone script reads state scoped by `context.worldID`. No game behavior is built into AdaEditor.

Edit the map as a normal `.ui` document. Select Airlock in Inspector to edit the companion source and bindings. The game supports one Companion Panel per scene. Multiple panels or missing sources produce diagnostics.

## AdaScript

```swift
@res var display: DisplayLayout;

func update(context) {
    if (display.isExpanded) {
        // display.secondary contains x, y, width and height in logical points.
        posture = "EXPANDED / CONNECTED";
    } else {
        posture = "COMPACT";
    }
}
```

`DisplayLayout` is a read-only runtime snapshot. Its fields are `state`, `isExpanded`, `primary`, `secondary`, and `hinge`; absent secondary/hinge fields are null. A wide ordinary window still reports one region. AdaptiveSceneView installs host geometry before scene startup and updates it before gameplay. CameraPlugin publishes native window geometry for conventional apps.

## Swift

The compiled Swift counterpart is in AdaExamples at `Examples/EngineDemos/Demos/UI/AdaptiveSceneViewExample.swift`:

```swift
AdaptiveSceneView(layout: .foldable(expanded: expanded), make: { app in
    // Install plugins and scene entities once.
}, updateContent: { world, _ in
    guard let display = world.getResource(DisplayLayout.self) else { return }
    // Use display.primary, display.secondary and display.hinge.
})
```

Build from the engine root: `swift build --product AdaptiveSceneViewExample`.
When preparing AdaScript before installing CameraPlugin, call `DisplayLayout.registerRuntimeType()` first, on the main actor.

## Boundaries

This release simulates layout regions; it does not read a hardware hinge sensor or render two independent cameras. Region coordinates are local to the application surface. A single scene runtime owns simulation; the additional panel is AdaUI. Play changes do not modify the saved scene. Preview configuration is saved in `.ada/project.json`.

Promo drafts and capture storyboard are in `Promo/`. Public posting and an App Store release are separate steps.
