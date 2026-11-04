# ``AdaNavigation``

Find walkable routes on immutable 3D navigation meshes and follow them with
physics-driven characters.

## Bake and query

Add the `AdaNavigationBaking` product to tools that build navigation meshes.
Runtime users need only `AdaNavigation`; it does not depend on Recast, rendering,
ECS, or a physics world.

```swift
import AdaNavigation
import AdaNavigationBaking
import Math

let data = try await NavigationMeshBaker.bake(
    vertices: [[0, 0, 0], [0, 0, 10], [10, 0, 10], [10, 0, 0]],
    indices: [0, 1, 2, 0, 2, 3]
)
let navigation = try NavigationMesh(data: data)
let path = try await navigation.findPath(from: [1, 0, 1], to: [9, 0, 9])
```

The returned game route is named `NavigationRoute`, so it can be used alongside
AdaUI's `NavigationPath` without an ambiguous type name.

## Save and load

```swift
let file = URL(fileURLWithPath: "playground.navmesh")
try data.encoded().write(to: file, options: .atomic)
let restored = try NavigationMeshData(encoded: Data(contentsOf: file))
let navigation = try NavigationMesh(data: restored)
```

Import Foundation for file I/O. Files carry a version, the pinned Detour layout,
agent settings and tile data. Loading validates section lengths, polygon and
detail vertex references, neighbor connections, bounding volume traversal,
finite coordinates and agent metadata before native code loads the tile.
The supported format is a single tile with 32-bit polygon references on
little-endian platforms. Unsupported versions fail explicitly.

`AdaScene` also provides `NavigationMeshAsset` for `AssetsManager.save` and
`AssetsManager.load`. Runtime loading needs only Detour, not the Recast generator.

Input triangles use world coordinates, Y up, and upward-facing winding on
walkable surfaces. Include the collision geometry of walls and ceilings, not
only floors. Radius erosion reserves clearance for the agent's center. Different
agent sizes require appropriate bakes. The default climb is zero because the
engine's character mover does not yet implement step climbing. Recast also uses
climb to connect neighboring raster cells on slopes, so a zero climb can split
ramps. Configure a nonzero climb for sloped scenes only after checking that the
same scene is traversable by the chosen character mover.

Queries project endpoints inside `projectionExtents`, run Detour's polygon
search, then extract funnel corners. Keep the projection's Y extent below the
separation between floors. Partial routes are rejected unless explicitly enabled;
their endpoint is not the requested destination. Node exhaustion is distinct from
an unreachable target, and insufficient corridor/corner buffers throw an error.
The search produces a valid corridor, not a guarantee of a globally shortest path.

## Follow with a character

Install `Navigation3DPlugin()` alongside `Physics3DPlugin()` in the scene's
`AppWorlds`, then attach these components to a root entity:

```swift
var follower = NavigationPathFollower()
follower.follow(path)

world.spawn {
    Transform(position: [1, 0, 1])
    CharacterController3DComponent()
    NavigationAgent3DComponent(follower: follower)
}
```

These integration types belong to `AdaScene` and are available through
`import AdaEngine`. The agent uses the physics controller's braking acceleration.
The scheduler runs navigation after body writeback and before character movement;
only the character controller writes the position. Give the controller dimensions
and slope limits compatible with the bake. The follower slows for corners, stops
at the endpoint, and reports `blocked` when the actual position stops changing.
Call `follow` with a replacement route after a target change or blockage, or call
`cancel` to stop issuing motion requests.

## Automatic requests

Install a map resource and add a destination to each character:

```swift
world.insertResource(NavigationMap3D(mesh: navigation))
world.spawn {
    Transform(position: [1, 0, 1])
    CharacterController3DComponent()
    NavigationAgent3DComponent()
    NavigationTarget3DComponent(destination: [9, 0, 9])
}
```

`Navigation3DPlugin` queries the current target and assigns the route. Change the
target component to move somewhere else; set its destination to nil to stop.
Blocked and failed requests retry after `repathInterval`. A replacement
`NavigationMap3D` resource invalidates existing routes after a new bake. Replies
are discarded if the target, map, request or entity changed during the query.
The per-update request limit bounds work and rotates through waiting agents.

Use `debugTriangles()` on the mesh to obtain world-space polygon fans for overlays.

## AdaScript

The host installs `Physics3DPlugin`, `Navigation3DPlugin` and a baked `NavigationMap3D`.
Install navigation before compiling scripts so constructors and query metadata are registered.
Scripts use the same components and scheduler as Swift; no direct native mesh or ECS pointers
are exposed to the VM or AOT module.

```javascript
@system(id: "robot.navigation")
class RobotNavigation {
    @query(NavigationAgent3DComponent, NavigationTarget3DComponent) var robots;
    var started = false;

    func update(context) {
        for (var row in robots) {
            if (!started) {
                row.navigationAgent3DComponent.maximumSpeed = 3.0;
                row.navigationTarget3DComponent.destination = [8.0, 0.0, 4.0];
                started = true;
            }
            if (row.navigationAgent3DComponent.hasArrived) {
                row.navigationTarget3DComponent.destination = null;
            }
        }
    }
}
```

Assign a new vector to change the goal, or `null` to cancel. Agent `state`, `errorCode`,
`hasArrived`, `hasPath`, `pathPointCount` and `routeLength` are read-only. `state` is one of
`idle`, `following`, `arrived`, `partialEnd`, `blocked` or `failed`; `errorCode` is empty
on success and otherwise names the `NavigationError` case. Scripts can write `maximumSpeed`,
`arrivalTolerance`, `repathInterval` and `targetRepathDistance`. State reflects the last
completed navigation/physics update, so a goal assignment need not change state immediately.

`NavigationAgent3DComponent()` and `NavigationTarget3DComponent(destination: [8.0, 0.0, 4.0])`
are available in deferred `world.spawn`/`world.insert` calls. Provide Transform and the physics
controller on the character as usual. The host still owns mesh baking, loading and map installation.

## Playground demo

Set `ADAEXAMPLES_PATH` to a clone of [AdaExamples](https://github.com/AdaEngine/AdaExamples).

Run `swift run --package-path "$ADAEXAMPLES_PATH/Examples/Technical/Navigation" NavigationDemo` for a 3D playground with a robot and obstacles.
On Windows, use `./script/run_navigation_demo_windows.ps1`; it selects the checked-in
AdaScript runtime and prepares the shader compiler automatically.
Click the floor to choose a destination. Buttons cycle goals, toggle the mesh,
reset the robot and rebake the playground. The displayed cyan mesh and yellow
route come from the actual navigation queries.
The robot initially patrols four goals using the bundled `NavigationRobot.ada`. Clicking the
floor switches to manual goals; the **Патруль AdaScript** button resumes the script.

`NavigationDemo --validate` runs the same fixture, file round trip, automatic
requests and physics movement without creating a renderer. To build without GPU
dependencies on Windows, use `$env:ADAENGINE_HEADLESS='1'` before
`swift run --package-path "$ADAEXAMPLES_PATH/Examples/Technical/Navigation" NavigationDemo --validate`. Clear that setting for the interactive demo.

`NavigationDemo --capture /absolute/path/playground.png` renders offscreen using
the real GPU backend, checks viewport mouse picking, and saves the resulting frame.
`NavigationDemo --validate-script` runs the bundled AdaScript patrol through all four goals
with real navigation and physical movement, without a renderer.
On Windows, `./script/run_navigation_demo_windows.ps1 -ValidateScript` runs that check.

## Current scope

The implementation supports static single-tile bakes, persisted assets,
actor-isolated queries, bounded automatic requests and physics-driven following.
It does not yet include general scene geometry collection, editor inspector
baking, off-mesh links, dynamic tile updates, or crowd avoidance. Bake a replacement
mesh after scene geometry changes, then install a new map resource. Keep unrelated
movement systems from also controlling a navigation agent's desired velocity.

Recast and Detour v1.6.0 are vendored under the Zlib license. See
`Sources/RecastNavigation/UPSTREAM.md` for the pinned revision.
