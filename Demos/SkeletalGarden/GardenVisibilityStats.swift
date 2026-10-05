import AdaEngine
import Foundation

@PlainSystem
struct GardenVisibilityStatsSystem {
    @Query<Entity, GardenCamera> private var cameras
    @Res<Render3DVisibilityStatistics?> private var statistics
    @Res<DeltaTime> private var time
    @Local private var elapsed: Float = 0
    @Local private var intervalStart: Double = 0
    @Local private var frames = 0

    init(world _: World) {}

    @MainActor
    func update(context _: UpdateContext) {
        let now = ProcessInfo.processInfo.systemUptime
        if intervalStart == 0 { intervalStart = now }
        frames += 1
        elapsed += min(max(time.deltaTime, 0), 0.1)
        guard elapsed > 0.5, let statistics else {
            return
        }
        let fps = Double(frames) / max(now - intervalStart, 0.001)
        frames = 0
        intervalStart = now
        elapsed = 0
        let snapshots = statistics.snapshots
        cameras.forEach { entity, _ in
            guard let count = snapshots["\(entity.id):camera"] else {
                return
            }
            let title =
                "Skeletal Garden · \(String(format: "%.1f", fps)) FPS · meshes \(count.visibleMeshes)/\(count.candidates)"
                + " · tris \(count.triangles) · draws \(count.drawCalls) · LOD \(count.lodInstances)"
            if ProcessInfo.processInfo.arguments.contains("--profile-frames") {
                gardenLog("[SkeletalGarden] frame-stats fps=\(fps) meshes=\(count.visibleMeshes) draws=\(count.drawCalls) triangles=\(count.triangles)")
            }
            if let manager = UIWindowManager.shared {
                for entry in manager.windows.values { entry.value.title = title }
            }
        }
    }
}
