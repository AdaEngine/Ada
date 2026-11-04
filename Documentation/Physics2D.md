# 2D physics

## Collider transforms

Shape coordinates and offsets are local to the body. A box's `angle` is a
counterclockwise local rotation in radians. Its vertices are rotated first,
then translated by the local offset, then scaled by the entity's scale.
The entity's rotation and position place that geometry in world space:

`worldPoint = bodyPosition + bodyRotation * (entityScale * (shapeRotation * vertex + offset))`

```swift
let shape = Shape2DResource.generateBox(
    width: 4, height: 1, center: [3, 0], angle: .pi / 2
)
```

With entity scale `[2, 1, 1]` this box is centered six units along the body's
local X axis and spans two units along X and four along Y before body rotation.
Polygon vertices and offsets follow the same local scale convention.

`offsetBy(x:y:)` returns a new resource, replacing the existing local offset;
it preserves the shape's other properties, including box rotation.
Circle offsets are scaled too. Circle radius retains the existing X-scale
convention; nonuniform scaling does not create an ellipse. The historical
`generateCircle(radius:)` size convention is unchanged by this compatibility fix.

Existing encoded boxes without `angle` decode as zero local rotation. Older
box data without an offset decodes with a zero offset. Body rotation is applied
on creation for both collision and physics bodies; rotating a static collider
without moving it is synchronized before the next simulation step. Simulated
rotation writes back to `Transform` using the same counterclockwise convention.

## Capsules and rounded convex shapes

The throwing factories `generateCapsule(from:to:radius:)`,
`generateRoundedBox(width:height:radius:center:angle:)` and
`generateRoundedPolygon(vertices:radius:)` reject invalid geometry with
`Shape2DGeometryError`. Decoding these new resource kinds applies the same validation.

Capsule endpoints are the local centers of their semicircular caps. Their
separation must exceed native linear slop (0.005 meters with default units).
The radius is the actual cap radius, independent of the historical circle factory convention.

Rounded-box dimensions include the corner arcs. Its corner radius must be
smaller than half the smaller outer dimension. Rounded-polygon vertices instead
describe a convex core: its radius expands beyond that core. Supply 3...8 convex
points; interior, duplicate and degenerate points are rejected.

Offsets and core vertices follow the local transform convention above.
For capsules and rounded polygons, rounding remains circular: radius is multiplied
by the larger absolute XY scale. Nonuniform scale therefore gives a conservative
round approximation, not an ellipse. Geometry collapsed by entity scale is not
registered as an invalid native shape and does not trip native hull assertions.

## Segments and chains

`generateSegment(from:to:)` creates a two-sided zero-thickness collider.
`generateChain(points:isLoop:ghostStart:ghostEnd:)` creates an owned one-sided
chain; `generateChainSegment(from:to:ghostStart:ghostEnd:)` creates a loose
one-sided segment. The front face lies on the right of each directed edge:
write horizontal floor points from right to left to face upward. Closed loops
must not repeat their first vertex. Ghosts default to linear extrapolation on
open endpoints. Degenerate, duplicate and intersecting chain geometry is rejected.

Offsets/scales are applied to points and ghosts. Mirrored entity scale reverses
the sequence to preserve the authored front side. Native chains have zero mass
and are intended for static terrain. They inherit material, filters and event
flags; all child segments are destroyed with the owning body. A sensor chain
uses body-owned loose sensor segments because native chain definitions cannot
set `isSensor`. Compound/chain events and query hits remain per shape pair;
several segments belonging to one entity can produce several hits.

## Overlap queries

Call the main-actor methods `world.overlap(at:)` for point containment,
`world.overlap(in:)` for broad-phase Rect/AABB candidates, and
`world.overlap(shape, at: transform)` for exact convex-shape overlap.
The shape overload accepts circles, capsules, boxes, rounded/ordinary convex
polygons and two-sided segments; chains are not convex query volumes and throw
`Physics2DQueryError.unsupportedShape`. Invalid poses/geometry throw typed errors;
invalid point or rectangle inputs return no hits. Query transforms follow the
same local geometry, scale and body rotation convention as collider creation.

Masks select shape categories (and native symmetric query filtering still
applies). Sensors are included by default; use `includeSensors: false` to omit
them, and `excluding: [entity.id]` to exclude an entity's complete compound shape.
`Overlap2DHit` is per shape, sorted by entity ID then shape ID. Its `shapeID` is
an ephemeral native identifier within this world, not a persistent asset ID.
Callers needing unique entities can deduplicate by entity ID explicitly.

### Convex sweeps

`try world.shapeCast(shape, from: pose, to: destination, query: .first)` sweeps
one convex volume at fixed rotation and scale. `.all` returns every native
shape hit in travel-distance order; `.first` clips at the closest accepted hit.
The distance measures movement of the pose origin, not distance to the surface.
The same masks, sensor option and entity exclusions apply as in overlap queries.
Initial overlaps have fraction/distance zero and a zero normal; zero motion uses
exact overlap. Chains can be targets but cannot be swept as query volumes.
Thin boxes use analytic vertices so hull welding does not discard them.

### Distance and rope joints

Attach `PhysicsJoint2DComponent(joint: descriptor)` to a joint-owner entity (no
Transform is required). `try PhysicsJoint2DDescriptor.distance(entityA:entityB:settings:)`
connects two entities in the same world. `DistanceJoint2DSettings` supports rigid
rest length, optional spring, lower/upper distance limits and a bounded motor.
`JointFrame2D` anchors are body-local physical coordinates, independent of entity
scale. Spring frequency is in Hz, damping ratio is dimensionless, length/speed
use world length units, motor effort is force.

The legacy `rope(entityA:entityB:)` factory now creates a real cable whose maximum
length is measured when both bodies first resolve; it allows slack. Body creation
can be deferred. Read `isConnected` and `jointError` on the component for status.
Replacing `jointDescriptor` reconnects at the next physics sync. Removing the
owner/component/body releases the constraint; a recreated body reconnects on the
next sync. Runtime records do not keep bodies or worlds alive, and native world
destruction releases all remaining constraints. New distance factories and decoded
settings reject nonfinite/invalid values before native calls.

### Revolute hinges

`revolute(entityA:entityB:settings:)` connects body-local frames with an optional
angular spring target, angle limits and a bounded rotational motor. Angles and
speeds use radians and radians/second; motor effort is torque. Limits must stay
inside +/-0.99 pi. `revolute(entity:worldAnchor:...)` pins a body to a world point
and measures angle from its orientation when resolved. The original one-entity
`revolute(entityA:)` pins its origin at the initial world position. Both world
variants own a static native anchor body, released when the joint is removed.

### Sliders, welds and pair filters

`prismatic(entityA:entityB:settings:)` slides along frame A's local X axis,
locks the relative frame rotation, and supports a translation spring target,
limits and force-bounded motor. Rotate both local frames to author an upright
slider without rotating the attached body. Translation and speed use world
length units; spring frequency/damping follow the distance-joint convention.
`weld(entityA:entityB:settings:)` aligns two local frames rigidly or with separate
linear/angular springs. `filter(entityA:entityB:)` only suppresses pair collision.
Removal restores collision even for stationary, already overlapping bodies:
the wrapper refilters the pair before native joint destruction.

### Suspension and motor joints

`wheel(entityA:entityB:settings:)` provides suspension along frame A's local X
axis, optional travel limits, and a torque-bounded wheel motor. For vertical
suspension set frame A's angle to pi/2 (Box2D 3.2 uses X, not a separate axis
vector). Unlike a slider, wheel rotation remains free.
`motor(entityA:entityB:settings:)` controls relative linear/angular velocity and
can independently align the two frames using position/angle springs. Velocity
force/torque bounds and spring force/torque bounds are independent. A nil motor
spring disables its position control; default zero velocity with finite effort
acts as friction. Every bound is finite and nonnegative.

### Live joint settings

Use the main-actor mutating `PhysicsJoint2DComponent.updateSettings(...)`
overloads with distance, revolute, prismatic, weld, wheel or motor settings.
They validate before native calls, preserve the native joint ID, wake attached
bodies, and update the component's descriptor so coding/reconnection retains
the settings. Keep and edit your settings value when changing one field.
World hinges retain their original pivot/reference angle while retuning.
A disconnected joint or a pending descriptor replacement throws `notConnected`;
a settings type for another joint throws `unsupportedControl`. To defer changes
until bodies exist, replace `jointDescriptor` instead.

### Thresholds and breakable connections

Use `descriptor.withBreakSettings(JointBreak2DSettings(...))` or live
`component.updateBreakSettings(...)` to opt into force/torque thresholds.
Nil thresholds disable reporting. `Joint2DEvents.ThresholdExceeded` reaches both
world-scoped subscriptions and ECS `Events`. Reporting occurs once per contiguous
run of native over-threshold reports; sleeping joints are not reported. Loads in
the event are sampled at step end, while a threshold can be exceeded in a substep.
With `removeOnBreak: true` the wrapper destroys the native joint, sets `isBroken`
and keeps it broken across body recreation. Call `reconnect()` or replace the
descriptor to reconnect on the next sync. `removeOnBreak: false` only notifies.
Broken state is transient simulation state; configuration is serialized.
All IDs/loads are snapshotted before removals and subscriber delivery, so a
subscriber may safely remove connected entities. Box2D itself reports thresholds
without destroying joints; removal is the wrapper's explicit policy.

### Dynamic mover and pogo joints

`mover(entityA:entityB:settings:)` controls relative world X/Y velocity with
separate per-axis force caps and leaves rotation free. Its live settings overload
updates velocity and force bounds in place. `pogo(entityA:entityB:settings:)`
provides spring support: spring length is measured along frame B's local Y axis,
while the normalized world normal sets the direction of support force. Tension
and compression have independent bounds. Initial impulse/velocity allow carrying
native state when rebuilding support. Native live pogo setters cover spring and
rest length through `updatePogoSpring`; normal/bound changes use a new descriptor.
Pogo is marked experimental upstream. Its position correction deliberately avoids
injecting body velocity; keep an actively driven mover awake while correcting a
target. Both types allow pair collision by default for physical character support.

### Query-based 2D characters

Add `CharacterController2DComponent` and `Transform` to a root entity. Its position
is the capsule bottom; physical radius/height are independent of visual scale and
rotation. Set `desiredVelocity.x` (Y is ignored) and set `jumpRequested` on press
edges. Fixed-step movement includes acceleration/braking, world Y gravity, jump,
walkable-slope normals, wall/ceiling/corner sliding, and descending ground snap.
Snap follows small descending steps; there is no arbitrary stair-climb algorithm.
The controller ignores sensors and honors both masks in its `CollisionFilter`.
Read actual `velocity`, `isGrounded`, `groundNormal`, `groundPoint`, `groundEntityID`
and `lastError`. External position changes or `resetMotion` clear accumulated
motion. A PhysicsBody2D/Collision2D component on the same entity is a reported
conflict; the controller does not move it. Invalid settings/motion are rejected
before native queries. Settings/filter are serialized; input and motion are not.

This virtual capsule queries the world and registers no body for other characters;
it does not push dynamic bodies. For manual fixed-step use, call the main-actor
`try world.moveCharacter(&controller, position: &bottom, deltaTime: dt)`.
Motion state has value semantics when copied; native plane storage is reused.
Sweeps skip sensors/self and include native one-sided chain tests. Plane queries
preserve chain fronts and convert Box2D 3.2's shape-local core support point to the
actual world surface, including rounded geometry.

### Dynamic character mode

Set `controller.mode = .dynamic` before the physics sync. The engine owns an
upright native capsule, an empty static air anchor, a mover and ground pogo
support. The collider pushes rigid bodies; motor and spring efforts are bounded
by `controller.dynamics`. Input, jump, slope limits, filters and status match the
query mode. Physical capsule size ignores visual scale/rotation, and the visual
rotation is preserved. Mover velocity is relative to the support body's motion;
pogo anchors track its world contact point, including vertically moving platforms.
The character body stays awake for active pogo correction, with contact recycling
disabled. Native contacts remain enabled; force bounds apply to the drive/support
joints. Ordinary joints can attach to a dynamic character entity.

Only Box2D integrates the dynamic body. Position/ground status are published after
writeback, and jumps inherit the support point's vertical velocity. Teleports reset
drive/support state; geometry and mode changes apply at physics sync. Removing a
component/entity or switching to query mode explicitly destroys the owned bodies
and joints, even if a component/runtime copy is retained. Dynamic mode requires
ECS scheduling; manual `moveCharacter` is for query mode. Static/kinematic bodies
retain zero native mass when applying authored mass properties, so moving support
platforms follow their velocity instead of receiving gravity.

### Runnable coverage

`Examples/Technical/Physics2D` contains ray/event, geometry/query, nine-mechanism and character
playgrounds. Its `--validate` mode runs the same scene setup deterministically;
`script/build_and_run.sh --verify` stages a native macOS app, exercises controls,
checks live state/re-entry and saves real Metal GPU frames and verification JSON.
The local Box2D 3.2 torque-query patch for linear mover/pogo joints is recorded in
`Sources/box2d/ADAENGINE_PATCHES.md`; it prevents native getter/debug assertions.

See [Advanced 2D physics and large-world coordinates](Physics2DAdvanced.md) for body controls, extended materials, wind, complete contacts, solver tuning and the precise-position APIs.
