# Animate a 3D character from movement

Use `CharacterLocomotion3DComponent` to play skeletal animations from an upright 3D character's
actual movement. Add it to the root entity that owns the character controller and skinned model.
Your input or AI continues to set `desiredVelocity` and `jumpRequested`. Locomotion reads the
resolved motion after physics, so holding forward against a wall can leave the character idle.

## Set up your character in Swift

Enable the 3D model and physics plugins in your game. Add a static floor and put your skinned
model in the project assets. This example uses `Character.glb` and the default clip names.
Spawn the character's root entity in the scene world.

```swift
let character = world.spawn("Character") {
    Transform(position: [0, 0.005, 0])
    CharacterController3DComponent()
    Model3DSource(source: "@res://Character.glb", animation: "Idle", autoplay: true)
    CharacterLocomotion3DComponent()
}

// Set these from your input system. Request a jump once on the press edge.
character.components[CharacterController3DComponent.self]?.desiredVelocity = [0, 0, 1.65]
// To run, increase horizontal speed to 3.3.
// To jump, set jumpRequested to true.
```

The default component maps `Idle`, `Walk`, `Run`, `Jump`, `Fall`, and `Land`.
After the character accelerates it walks, then runs at the higher speed. Releasing movement
returns it to idle after braking. `Jump` plays on ascent, `Fall` holds its final pose during
descent, and `Land` plays briefly before the character resumes the current grounded gait.
Stepping off a ledge goes straight to `Fall` after two consecutive ungrounded physics samples.

## Set up your character in Ada Studio

In Ada Studio's desktop scene inspector, select the root entity that owns the model and
controller. Choose **Add Component**, then **3D Locomotion**. Assign the six clip slots to your
model's animations before starting the scene.

- **Facing** controls whether the character turns toward its movement and which axis on
  the model points forward.
- **Clips** lists animations from the model and its attached libraries. Choose a clip for
  each state. The inspector marks names that are missing or ambiguous. If a model swap fails
  because the new model lacks the previous startup clip, clear or update **Animation** on
  **3D Model** to load the new clip list.
- **Directional clips** opens in **Keep facing** mode. Pick a walk and run for each
  direction or use the forward clip. Saved assignments are available in either facing mode.
- **Timing and speed** controls clip playback rates and transition durations. Press Enter
  to apply a number. Save the scene to keep the settings. Use Undo or Redo to revisit an edit.

In Swift, configure the same fields through `CharacterLocomotion3DComponent.Configuration`.

Set `configuration.clips` to the exact names of the six clips on your model. Use in-place
clips. The controller moves the character and locomotion plays the poses. Match the walk
and run reference speeds to the authored strides to reduce foot sliding.

- `turnToMovement` uses forward gaits and turns the root entity toward its resolved movement.
  The default forward axis is `positiveZ`. Set `forwardAxis` to match the model.
- `keepFacing` leaves the root orientation to your game. Set the optional
  `configuration.left`, `right`, and `back` gait mappings to use clips relative to that
  orientation. Each missing slot falls back to its forward gait. Align the footfall phase
  of directional, walk, and run loops for continuous transitions.

A model with a manual `ModelAnimationPlayback3DComponent` or an active animation graph
retains that playback. Inspect `diagnostic` to find conflicts, missing clips, and invalid
tuning. Scene serialization preserves the settings and each actor starts with independent
locomotion state. Scene data can omit settings that use the component defaults.

Locomotion uses the platform's existing 3D physics and skeletal playback. It samples one
controller result per fixed step and reuses the model's existing pose sampling and animation
LOD. Gameplay supplies input, the physics controller moves the character, and the existing
pose modifiers handle procedural adjustments such as foot IK.
