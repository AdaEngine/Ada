# Advanced 2D physics and large-world coordinates

These additive APIs use the bundled Box2D 3.2 backend. Existing component/material JSON remains readable, and unchanged settings retain their previous defaults. Live mutation belongs on the main actor between simulation steps.

## Body dynamics, motion and sleep

```swift
var body = PhysicsBody2DComponent(shapes: [.generateBox(width: 1, height: 1)], mass: 1)
var dynamics = body.dynamics
dynamics.isBullet = true
dynamics.safetyFactor = 0.02
dynamics.linearDamping = 0.4
dynamics.angularDamping = 0.8
try body.configureDynamics(dynamics)

var motion = body.motion
motion.lockTranslationY = true
motion.lockRotation = true
motion.isSleepEnabled = true
motion.sleepThreshold = 0.05
motion.initiallyAwake = false
try body.configureMotion(motion)
```

Both configure methods validate before changing any setting. Dynamics changes wake an existing body without recreating it. `safetyFactor` is nonnegative; Box2D recommends 0.01...0.5. Damping is velocity decay in inverse seconds. Bullet mode adds continuous checks against dynamic/kinematic bodies, excluding other bullets. Use relative-motion ray/shape casts when projectile timing needs stronger guarantees than native CCD provides.

`fixedRotation` is retained and combined with `motion.lockRotation` using OR. Live lock changes preserve authored mass/inertia. `initiallyAwake` applies only at creation; sync does not repeatedly force that state. Read `body.isAwake` and use `body.setAwake(true/false)` for explicit commands. Native sleeping/waking can affect a whole touching island.

## Rolling, conveyors and material mixing

```swift
var mixing = PhysicsMaterialMixing()
mixing.friction = .minimum
mixing.restitution = .maximum
mixing.priority = 10
mixing.identifier = 42
let material = try PhysicsMaterial.generate2D(
    friction: 0.6,
    restitution: 0.1,
    rollingResistance: 0.2,
    surfaceSpeed: 3,
    mixing: mixing
)
let belt = Collision2DComponent(shapes: [.generateBox(width: 10, height: 1)], material: material)
```

The existing `generate(friction:restitution:density:)` signature remains available. The validated 2D factory rejects nonfinite/negative physical coefficients; signed surface speed controls native conveyor direction. New fields default to zero/native mixing when decoding old material JSON. The 3D backend continues using its existing friction/restitution/density behavior.

Replace `PhysicsBody2DComponent.material` or `Collision2DComponent.material` to update all existing shapes, including chain segments, on the next sync. Native shape IDs remain stable. Density changes refresh shape-derived inertia while retaining the engine's authored mass policy; changed surfaces wake touching bodies, including sleeping objects on static conveyors.

Combine modes are native default, minimum, geometric mean, average, multiply and maximum. Higher material priority wins. Equal priority selects the higher enum raw value, independent of shape A/B order. The default is geometric mean for friction and maximum for restitution. Policies travel as immutable native ID bits, so solver workers need no mutable registry or captured world. Low 32 bits hold the user identifier; upper bits are reserved for the policy.

## Wind and aerodynamic drag

```swift
PhysicsWind2DComponent(.init(velocity: [8, 0], drag: 1))
// Or accumulate one step's force explicitly:
try body.applyWind(.init(velocity: [8, 0], drag: 1, wakeSleepingBodies: true))
```

The component submits force once before each native fixed step. Its absence adds no force. Still air (`velocity: .zero`, `drag: 1`) slows an already moving body through the native relative-motion model, independently of linear damping. Wind uses projected shape area and unit depth; lift is passed to the native, shape-dependent model. Circles, capsules and polygons are supported. Line geometry, static and kinematic bodies receive no aerodynamic force. Sensors are excluded unless explicitly included.

Sleeping bodies ignore wind by default. Explicit wake uses the adapter's safe pre-wake path before native force submission. The one-shot API returns whether eligible geometry was submitted, and invalid settings throw before native mutation. `PhysicsWind2DComponent.lastError` reports invalid live settings.

## Contact IDs, points and events

```swift
let contacts = physics.contacts(for: entity)
if let contact = contacts.first {
    for point in contact.manifold.points {
        print(point.id, point.globalPoint, point.separation,
              point.normalImpulse, point.tangentImpulse, point.totalNormalImpulse)
    }
    let current = physics.contactSnapshot(for: contact.id) // nil if expired
    let valid = physics.isValid(contact.id)
}
```

`Contact2DID` is opaque, hashable, transient and scoped to one world lifetime. It cannot be used in another world or serialized as a durable reference. Body and per-shape queries return copied `Contact2DSnapshot` values with entity/shape IDs and the native A-to-B normal. Native contact destruction does not invalidate copied point data or retain the world.

Each point includes its feature ID, persisted flag, COM-relative world-space anchors, reconstructed global anchors/midpoint, nearby midpoint, signed separation, normal/tangent/total normal impulse and optional pre-solve normal velocity. Cached anchors are reconstructed against current centers; these positions are not exact time-of-impact coordinates. Speculative contacts may be separated and have zero total impulse.

`CollisionEvents.Began`, `.Hit` and `.Ended` expose `contactID` and optional `contact`. Begin/hit payloads, sensor payloads and their geometry are copied before joint/collision subscribers run, so deleting a body in an earlier callback does not cause later native-memory access. Delivery occurs once per simulation step. End handles can already have expired, with no remaining manifold; sensors have no solver contact ID/manifold. Events whose entities cannot be resolved at capture time are skipped.

Pre-solve delegates receive full `Manifold2D.points` with `.phase == .preSolve`. Their impulses are cached, and `normalVelocity` is nil. Post-solve normal velocity is available only when hit reporting was enabled. The pre-continuous callback has no manifold yet. Delegates may run on native worker threads: consume immutable data and synchronize any output instead of mutating UI/world/physics state inside them. Point arrays are not allocated for unused delegates.

## Solver configuration

```swift
var settings = physics.solverSettings
settings.substepIterations = 8
settings.contactHertz = 30
settings.contactDampingRatio = 1
settings.contactPushSpeed = 3
settings.restitutionIterations = 8
settings.isRestitutionPropagationEnabled = true
settings.maximumLinearSpeed = 100
try physics.configureSolver(settings)
```

The typed API also covers restitution/hit thresholds, authored contact recycle distance, sleeping, continuous collision and warm starting. Validation is atomic; restitution iterations range from 0 to the bundled native maximum (63 in 3.2). Restitution propagation is experimental and can be expensive. Defaults come from the bundled native world definition.

World JSON now retains the complete configuration and coordinate origin, with defaults for legacy resources. A pre-solve/filter delegate temporarily forces effective recycling distance to zero; the authored setting remains readable in `solverSettings` and is restored when the delegate is removed. `effectiveContactRecycleDistance` shows the applied value. Dynamic characters keep their per-body recycling disabled independently. Invalid legacy raw substep/delta values skip stepping instead of trapping during integer conversion.

## Exact global positions and nearby rendering

Box2D is compiled with one consistent Double world-position ABI for C and Swift. `PhysicsPosition2D` preserves global XY values; local geometry, displacement, velocities and rotations remain Float. Render matrices remain Float in a nearby coordinate frame.

```swift
let origin = PhysicsPosition2D(x: 1_000_000_000.125, y: -1_000_000_000.25)
physics.setCoordinateOrigin(origin)
let entity = world.spawn {
    Transform()
    PhysicsPosition2DComponent(origin.offset(by: [0, 2]))
    PhysicsBody2DComponent(shapes: [.generateBox(width: 1, height: 1)], mass: 1)
}
let hits = physics.raycast(from: origin, translation: [10, 0])
```

The position component is authoritative. Edit it to teleport an ECS-owned global root; `Transform.position.xy` is its render-relative projection. It works for rigid bodies, collision-only geometry and nonphysical roots such as cameras. Tag every root that should retain its global position across an origin change, including stationary colliders and the camera. Request origin changes before physicsSync (for example, during fixedPreUpdate), so body and camera projections update in the same frame. Children can inherit their parent's nearby transform; placing the global-position component on a parented entity reports `parentedEntity` and prevents unsupported physics synchronization.

Untagged Vector2 position APIs use the current nearby frame, preserving original behavior at origin zero. `body.precisePosition` and `preciseWorldCenter` read exact native positions. `setGlobalPosition` teleports an already created body; with an authoritative position component, update that component as well. Double inputs must originate as Double values: widening an already rounded Float cannot recover precision.

Precise queries include `overlap(atGlobal:)`, convex `overlap(_:atGlobal:rotation:scale:)`, nearby AABBs with `relativeTo:`, and `shapeCast(_:from:translation:)` using a PhysicsPosition2D origin. Force/impulse APIs accept `atGlobalPoint:`. Ray/cast/hit results retain global points; reproject them using the current origin if the frame changed after capture.

Both character modes, exact global revolute anchors, native debug geometry and ordinary joints use the same coordinate contract. An origin change projects render roots without teleporting native bodies or recreating their contacts/joints. Local/native broad-phase bounds remain Float and grow conservative padding far from zero; Double global positions do not turn all local geometry or broad-phase math into Double.

## Runnable acceptance

`Examples/Technical/Physics2D` includes an Advanced tab with conveyors/rolling/mixing, wind/drag/damping, axis and sleep controls, a bullet crossing a thin kinematic target, contact point markers and solver presets. The controls use only public runtime APIs.

From an AdaExamples checkout, run `Examples/Technical/Physics2D/script/build_and_run.sh --verify` to build/stage/open the native app and generate actual scene GPU frames plus `dist/proof/verification.json`. The executable's `--validate` mode runs deterministic simulation checks without opening a window. Generated bundles and proof files are ignored.

The Large worlds tab simulates at global coordinates near 1e9. Its one-millimeter target nudge changes an actual precise ray hit; shifting the render origin keeps the camera view, contact identity and exact hinge intact. Movement/jump and mode controls exercise both virtual and dynamic characters there. Native proof includes `large-world-before.png`, `large-world-shifted.png` and `large-world-dynamic.png`, plus scene re-entry and handle-isolation checks.

Local acceptance for this implementation: 207 physics/fixed-step/2D+3D character tests across 46 suites passed; 55 changed Swift files passed SwiftLint with zero violations. All seven deterministic scenes and seven native Metal screens passed. These focused results do not imply a green full package run: full-suite execution failed to find TextureAtlasBuilderTool in the custom scratch layout and stopped in AdaUIDebug3DTests at Texture2D.swift:84 because RenderEngine.shared was uninitialized. Those renderer/asset/test files are unchanged by this feature. Windows, browser and CI validation are separate and were not run here.
