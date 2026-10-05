import AdaECS
import AdaRender
import Math
import Synchronization

/// Per-view light/atlas counters, separate from GPU pass timings.
public final class Render3DLightStatistics: Resource, Sendable {
    public struct Snapshot: Codable, Sendable {
        public var sceneLocalLights: Int
        public var selectedLocalLights: Int
        public var pointLights: Int
        public var spotLights: Int
        public var directionalLights: Int
        public var shadowLights: Int
        public var shadowFaces: Int
        public var atlasWidth: Int
        public var atlasHeight: Int
    }
    private let state = Mutex<[String: Snapshot]>([:])
    public init() {}

    func record(view: Entity.ID, scene: ExtractedLighting3D, entry: LocalShadow3DViews.Entry) {
        let selected = entry.lights.filter { entry.allocator.slots[$0.entity] != nil }
        let value = Snapshot(
            sceneLocalLights: scene.localLights.count,
            selectedLocalLights: entry.lights.count,
            pointLights: entry.lights.filter { $0.kind == .point }.count,
            spotLights: entry.lights.filter { $0.kind == .spot }.count,
            directionalLights: scene.directionalLights.count,
            shadowLights: selected.count,
            shadowFaces: selected.reduce(0) { $0 + ($1.kind == .point ? 6 : 1) },
            atlasWidth: entry.color?.size.width ?? 0,
            atlasHeight: entry.color?.size.height ?? 0
        )
        state.withLock { $0["\(view)"] = value }
    }

    func retainViews(_ views: [Entity.ID]) {
        let keys = Set(views.map { "\($0)" })
        state.withLock { state in
            for key in state.keys where !keys.contains(key) { state.removeValue(forKey: key) }
        }
    }

    public var snapshots: [String: Snapshot] { state.withLock { $0 } }
}
