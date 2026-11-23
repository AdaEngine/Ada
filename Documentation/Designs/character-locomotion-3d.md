# 3D Character Locomotion

Status: **Accepted.**

Approval: explicit approval in the Codex conversation on 2026-11-22.

This design extends [Animation Authoring](animation-authoring.md#7-animation-graph-extensions)
with a ready-to-use runtime preset for an upright 3D character. A game supplies movement intent
to its existing character controller and maps the model's clips once. The engine then selects and
crossfades clips from the character's resolved movement. The tests use GardenRobot as the reference character.

## Character setup

Add a serializable `CharacterLocomotion3DComponent` to a root entity with `Transform`,
`CharacterController3DComponent`, and a skinned `Model3DSource`. It is enabled by the 3D model
pipeline when the scene also uses 3D physics. The owner resolves the imported animation player
through `Model3DSourceState`. Saving or duplicating a scene persists the configuration and starts
each instance with fresh runtime state.

The configuration maps six required slots to clip names. GardenRobot already has `Idle`, `Walk`,
`Run`, `Jump`, `Fall`, and `Land`, so the reference mapping uses those names directly. An author
can configure the walk/run reference speeds, transition durations, and facing mode. Directional
walk/run clips are optional. Configure through Swift or scene data using the existing component
serialization path. A dedicated Studio editing surface belongs to a separate proposal.

Skeletal Garden already implements this loop in `GardenAnimationSystem` in the AdaExamples
project. It keeps facing, air, and landing history in shared script fields. The engine example uses
the same GardenRobot GLB already present under `Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets`.
An AdaEngine example and integration test exercise the preset directly. A later migration of the
external sample can keep its input, camera and respawn code and replace its animation system with
the preset.

## Grounded movement and direction

Use `length(velocity.xz)` from `CharacterController3DComponent` for gait selection. Pushing
against a wall with zero displacement settles to `Idle`. Sliding along a wall uses the actual
remaining direction. Vertical displacement on a slope leaves the grounded gait unchanged.

| Tuning | Default value |
| --- | --- |
| Leave idle / return to idle | 0.16 / 0.07 m/s |
| Enter run / leave run | 2.475 / 2.1 m/s |
| Walk / run playback reference speed | 1.1 / 2.2 m/s |
| Facing dead zone | 0.07 m/s |
| Gait fade / transition involving an air or landing state | 0.22 / 0.08 s |

Each higher-speed state enters at or above its upper threshold and exits at or below its lower
threshold. Direct `Idle` to `Run` and `Run` to `Idle` changes are allowed. Walk and run playback
rates use actual speed divided by the corresponding reference speed, clamped to 0.25–1.5.
Grounded gait changes preserve normalized clip phase across compatible looping gait clips.
Directional clips within that set should share a footfall phase. Idle starts on entry and loops
at its authored rate. Continuing a gait updates its rate without restarting the clip.

**Turn to movement** is the GardenRobot mode. Play forward gaits and ease the owner's yaw toward
the resolved world-space direction along the shortest arc. The model's authored forward axis is
configurable, with `+Z` for GardenRobot. Use a response of 12 per second and a stable choice at
exactly 180 degrees. Keep the last yaw below the movement dead zone. Rotate on the ground and in
the air while horizontal motion exceeds the dead zone. This mode owns the upright owner's yaw,
including the facing inherited by attachments. The controller still owns position and the upright
capsule is unaffected by yaw.

**Keep facing** lets gameplay own orientation while locomotion selects forward, left, right or back
gaits from velocity relative to that facing. Use four 90-degree sectors and a 10-degree hysteresis
margin past the current sector boundary. Initialize to the nearest sector when movement starts,
giving clockwise sectors the exact boundary on ties when viewed from above. Include diagonal
movement through those same sectors. A missing directional slot uses the forward clip for that
gait. Air and landing clips are independent of the sector. GardenRobot demonstrates turning.
Distinct named directional clips in an additional test configuration verify strafing and backpedaling.

## Air and landing transitions

| Observation after a physics step | Result |
| --- | --- |
| Leaves ground while rising faster than 0.15 m/s | Enter `Jump` immediately and play it once. |
| Leaves ground otherwise | Enter `Fall` on the second consecutive ungrounded sample. A single ungrounded sample during grounded movement keeps the current gait. |
| `Jump` reaches the apex or hits a ceiling | Enter `Fall` once upward speed is at or below 0.15 m/s, even if `Jump` still has time left. |
| Next ungrounded sample after entering `Fall` | Stay in `Fall`. Play it once, then hold its last pose while airborne. |
| Regains contact after confirmed air | Enter `Land` once. For GardenRobot the landing window is 0.25 s. |
| Landing window ends | Choose the grounded gait from the current speed and direction. |
| Leaves ground during `Land` | Cancel `Land` immediately. Enter `Jump` if rising above the threshold, otherwise enter `Fall`. |

A first grounded sample initializes the gait directly. A first ungrounded sample begins `Jump`
or `Fall` immediately, so a character spawned above the ground can land normally. Teleport/reset
clears the previous contact history, landing window and direction hysteresis. The next resolved
sample follows the same initialization rules. A grounded teleport produces a grounded gait
without a synthetic landing. A new airborne episode can then land normally.

## Runtime ownership and compatibility

- `AdaScene` owns configuration, per-entity state, and binding to the existing skeletal player.
  `AdaPhysics` publishes a fresh resolved controller sample after each actual step, with an
  instance-local step identity and a reset indication that survives consumption of `resetMotion`.
  Locomotion consumes each sample once in `.fixedPostUpdate`. A paused physics gate or a skipped
  controller produces no sample and advances no locomotion timers.
- The fixed step owns gameplay state and elapsed landing time. Model playback consumes the
  resulting clip request in `.postUpdate` before skeletal pose evaluation. The existing player
  owns clip time, fades, modifiers and pose sampling. At most one new clip starts per published
  frame, using the latest fixed state. Catch-up ticks may finish a transient state between frames.
  Animation LOD affects pose sampling while the state machine still sees each physics step.
- Clip activation is tracked by state entry and player identity. A repeated render update never
  restarts a clip. Two looping gait slots mapped to the same clip keep its clock. Entering a
  one-shot again starts it at zero, including when it shares a clip name with the previous slot.
  A replacement player starts with its own clock. Validate mappings on bind and on relevant configuration or
  player changes. Missing or ambiguous clips, invalid tuning, and conflicting playback ownership
  expose a diagnostic and prevent locomotion from taking over. Loading, replacement, or an invalid
  configuration must keep the existing pose/player usable and allow recovery when corrected.
- An animation graph or a manual `ModelAnimationPlayback3DComponent` owns playback on any model
  that uses it. Locomotion reports the conflict and leaves both the model output and facing alone.
  Disabling or removing locomotion releases ownership and clears its state. In the absence of
  another writer the existing player retains its playback settings. A later valid enable starts
  from a fresh controller observation. Ordinary model autoplay may provide the starting pose
  while locomotion acquires its first sample.
- Root motion, a general-purpose graph state machine, blend spaces, foot IK, and camera or input
  changes are outside this preset. Use in-place clips. Root translation, collision, gravity and
  jump requests continue through the existing character controller and game input. The graph
  orchestration work in the animation authoring design remains the path for author-defined graphs.

Keeping the behavior in Garden.ada would preserve the example with each project responsible for
its own state and transitions. Implementing general graph orchestration first would provide
author-defined transitions, blending and layering at the cost of a larger change. The preset can
ship through the current clip player and demonstrates the same controller signals a later graph
binding can consume.

## Acceptance and user documentation

- An integration test loads the real GardenRobot through `Model3DSource`, steps 3D physics on a
  floor with a wall and ledge, and checks the selected clip, playback phase and visible-facing
  transform. Verify acceleration, running, braking, a 180-degree turn, wall contact and wall
  sliding, jump/apex, stepping off a ledge, a short ceiling hit and landing while holding move.
- Cover all facing sectors, boundaries, rapid turns and missing directional slots, plus timing
  around the speed thresholds. Check first spawn, grounded and airborne teleports, renewed jump
  during landing, stale physics samples, zero/multiple fixed ticks per frame, and render/LOD
  clock behavior. Run two independently controlled characters and verify save/reopen, rebind,
  invalid-configuration recovery, and compatibility with the manual clip and graph paths.
- Run the focused tests through the contributor runner. Use a disposable scene for native or
  WASM visual verification. Keep GardenRobot in the test fixtures. Cover the existing platform
  build/test matrix and record actual platform and backend evidence.
- Ship `Sources/AdaEngine/AdaEngine.docc/Articles/Developers/CharacterLocomotion3D.md` for game
  authors and link it under Guides in `Sources/AdaEngine/AdaEngine.docc/AdaEngine.md`. Include
  a minimal setup for the reader's own character, the clip mapping, the two facing modes, speed
  tuning, conflicts, and in-place clip requirements. Exercise the same component setup in the
  integration suite, verify the DocC build and navigation, and link the
  guide from [Animation Graphs](../AnimationGraphs.md) so users comparing playback options can find it.

## Studio inspector improvement

**Accepted.** The scene inspector provides editable locomotion settings on the character's root
entity. GardenRobot keeps its default mappings, so authors can add the component and use Play
immediately when the model and 3D controller are present.

- **Facing** contains the enabled toggle, facing mode and authored forward axis. **Clips**
  maps the six required states to clips available to the selected model. Use Studio's standard
  dropdowns. Keep GLB and library clip names as authored.
- **Directional clips** opens in Keep Facing mode. Each left, right and backward walk/run
  slot can select a clip or inherit its forward equivalent. Authors can expand the section in
  either mode to repair saved mappings that fail runtime validation. Switching modes preserves
  the stored mappings.
- **Timing and speed** shows walk and run reference speeds in meters per second, gait and
  air fade durations in seconds, and landing duration in seconds. These fields follow the
  runtime's finite-value and sign requirements. Show an inline error and retain the last
  committed value when a draft is invalid. Reference speeds control clip playback rate.
- While clips load or the model is unavailable, display the current mapping and a status
  next to the clip controls. If a model change leaves a stale or ambiguous mapping, show the
  affected value and let the author replace it when a valid clip is available. Show an
  actionable message for a missing controller or an animation graph or manual playback conflict.

AdaEditor owns the inspector fields, clip options and scene document edits. Reuse the resolved
model and animation-library clip metadata, matching the runtime's clip identity and duplicate
name rules. Treat the serialized configuration as the source of truth, fill absent fields from
runtime defaults, and preserve sibling mappings and unrelated data when editing a field.
Commit edits through the scene document's save and undo/redo path. AdaScene retains ownership of
clip selection, physics sampling and playback.

The first delivery targets the Ada Studio desktop scene inspector. Use existing section layout,
themed controls and the shared English/Russian localization. Validate the panel at narrow and
normal widths with keyboard and pointer input.

The visual proposal uses the scene component sections, controls and typography defined by the
existing inspector and [Studio control design](../../Editor/Documentation/Design/Controls.md).

Use a real GardenRobot scene to verify the defaults, select a clip, commit a numeric edit, switch
facing modes and verify the preserved mappings. Save, reopen, undo and redo through the normal
editor path. Check a missing clip, a model swap and a playback conflict. Update the existing
Character Locomotion guide under the AdaEngine Guides navigation with the inspector workflow for
the reader's own character. Verify the workflow in Studio and check the refreshed offline guide
snapshot alongside the DocC navigation.
