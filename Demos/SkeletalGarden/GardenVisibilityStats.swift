import AdaEngine

@PlainSystem
struct GardenVisibilityStatsSystem {
    @Query<Entity, GardenCamera> private var cameras
    @Res<Render3DVisibilityStatistics?> private var statistics
    @Res<DeltaTime> private var time
    @Local private var elapsed: Float = 0

    init(world _: World) {}

    @MainActor
    func update(context _: UpdateContext) {
        elapsed += min(max(time.deltaTime, 0), 0.1)
        guard elapsed > 0.5, let statistics else {
            return
        }
        elapsed = 0
        let snapshots = statistics.snapshots
        cameras.forEach { entity, _ in
            guard let count = snapshots["\(entity.id):camera"] else {
                return
            }
            let title = "Skeletal Garden · meshes \(count.visibleMeshes)/\(count.candidates) · tris \(count.triangles) · draws \(count.drawCalls) · LOD \(count.lodInstances)"
            if let manager = UIWindowManager.shared {
                for entry in manager.windows.values { entry.value.title = title }
            }
        }
    }
}
