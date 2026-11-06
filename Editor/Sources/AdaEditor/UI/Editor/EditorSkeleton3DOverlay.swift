@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Synchronization

/// Preview state shared by UI controls and the post-animation drawing system.
final class EditorSkeleton3DOverlay: Resource, Sendable {
    struct State: Sendable {
        var enabled = false
        var selected: Set<Int> = []
        var grid = false
        var axes = false
        var height: Float = 0
        var modifierHandles: [Vector3] = []
    }
    private let storage = Mutex(State())
    var state: State { storage.withLock { $0 } }
    var isEnabled: Bool {
        get { storage.withLock { $0.enabled } }
        set { storage.withLock { $0.enabled = newValue } }
    }
    var selectedNodes: Set<Int> {
        get { storage.withLock { $0.selected } }
        set { storage.withLock { $0.selected = newValue } }
    }
    var showsGrid: Bool {
        get { storage.withLock { $0.grid } }
        set { storage.withLock { $0.grid = newValue } }
    }
    var showsAxes: Bool {
        get { storage.withLock { $0.axes } }
        set { storage.withLock { $0.axes = newValue } }
    }
    var gridHeight: Float {
        get { storage.withLock { $0.height } }
        set { storage.withLock { $0.height = newValue } }
    }
    var modifierHandles: [Vector3] {
        get { storage.withLock { $0.modifierHandles } }
        set { storage.withLock { $0.modifierHandles = newValue } }
    }

    /// Skip helper nodes while preserving their transforms in the animated global pose.
    static func links(joints: [Int], rig: SkeletalRig) -> [(Int, Int)] {
        let jointSet = Set(joints)
        return joints.compactMap { child in
            guard rig.nodes.indices.contains(child) else { return nil }
            var parent = rig.nodes[child].parentIndex
            var visited: Set<Int> = [child]
            while let index = parent, rig.nodes.indices.contains(index), visited.insert(index).inserted {
                if jointSet.contains(index) { return (index, child) }
                parent = rig.nodes[index].parentIndex
            }
            return nil
        }
    }
}

struct EditorSkeleton3DPlugin: Plugin {
    func setup(in app: AppWorlds) {
        if app.main.getResource(EditorSkeleton3DOverlay.self) == nil {
            app.insertResource(EditorSkeleton3DOverlay())
        }
        app.addSystem(EditorSkeleton3DSystem.self, on: .postUpdate)
    }
}

/// Runs after skinning and transform propagation so bones and mesh use the same frame.
@PlainSystem(dependencies: [.after(SkeletalAnimation3DSystem.self), .after(ChildTransformSystem.self)])
struct EditorSkeleton3DSystem {
    @Query<SkinnedMesh3DComponent> private var skins
    @Query<Entity, ModelAnimation3DComponent, Transform> private var models
    @Res<EditorSkeleton3DOverlay> private var overlay
    @Res<DebugDraw3D> private var debug

    init(world _: World) {}

    func update(context _: UpdateContext) {
        let settings = overlay.state
        if settings.grid {
            for step in -20...20 {
                let value = Float(step) * 0.25
                debug.line(from: [value, settings.height, -5], to: [value, settings.height, 5], color: Color(0.5, 0.5, 0.5, 0.35), depthTested: true)
                debug.line(from: [-5, settings.height, value], to: [5, settings.height, value], color: Color(0.5, 0.5, 0.5, 0.35), depthTested: true)
            }
        }
        if settings.axes {
            let origin = Vector3(0, settings.height, 0)
            debug.line(from: origin, to: origin + [1, 0, 0], color: .red, depthTested: false)
            debug.line(from: origin, to: origin + [0, 1, 0], color: .green, depthTested: false)
            debug.line(from: origin, to: origin + [0, 0, 1], color: .blue, depthTested: false)
        }
        for index in stride(from: 0, to: settings.modifierHandles.count - settings.modifierHandles.count % 2, by: 2) {
            let anchor = settings.modifierHandles[index], point = settings.modifierHandles[index + 1]
            let color = index == 0 ? Color(0.2, 0.55, 1, 1) : Color(0.8, 0.3, 1, 1)
            debug.line(from: anchor, to: point, color: color, depthTested: false)
            for axis in [Vector3.right, .up, Vector3(0, 0, 1)] {
                debug.line(from: point - axis * 0.05, to: point + axis * 0.05, color: color, depthTested: false)
            }
        }
        guard settings.enabled else { return }
        models.forEach { root, animation, _ in
            guard let transform = EditorPicking.worldMatrix(for: root) else { return }
            var jointSet: Set<Int> = []
            skins.forEach { skin in
                if skin.modelRoot == root.id { jointSet.formUnion(skin.skin.joints) }
            }
            let joints = jointSet.sorted()
            let pose = animation.player.globalTransforms
            for (parent, child) in EditorSkeleton3DOverlay.links(joints: joints, rig: animation.player.rig)
                where pose.indices.contains(parent) && pose.indices.contains(child) {
                let start = (transform * pose[parent] * Vector4(0, 0, 0, 1)).xyz
                let end = (transform * pose[child] * Vector4(0, 0, 0, 1)).xyz
                debug.line(from: start, to: end, color: Color(0.15, 1, 0.75, 1), depthTested: false)
            }
            let scale = max(0.0001, (transform * Vector4(0.025, 0, 0, 0)).xyz.length)
            for joint in jointSet.union(settings.selected).sorted() where pose.indices.contains(joint) {
                let point = (transform * pose[joint] * Vector4(0, 0, 0, 1)).xyz
                for axis in [Vector3.right, .up, Vector3(0, 0, 1)] {
                    debug.line(from: point - axis * scale, to: point + axis * scale,
                               color: settings.selected.contains(joint) ? Color(1, 0.4, 0.1, 1) : .yellow, depthTested: false)
                }
            }
        }
    }
}
