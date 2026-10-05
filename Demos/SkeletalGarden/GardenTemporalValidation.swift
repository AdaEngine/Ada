import AdaEngine
@_spi(Internal) import AdaRender

@PlainSystem
struct GardenTemporalValidationSystem {
    @Query<Ref<Camera>> private var cameras
    @Local private var frame = 0
    private let enabled = ProcessInfo.processInfo.arguments.contains("--temporal-multi")
    init(world _: World) {}

    func update(context _: UpdateContext) {
        guard enabled else {
            return
        }
        frame += 1
        cameras.forEach { camera in
            guard case .texture = camera.renderTarget else {
                return
            }
            if frame == 20 { camera.temporalUpscaling?.resetGeneration += 1 }
            if frame == 35 { camera.temporalUpscaling?.renderScale = 0.75 }
            if frame == 60 { camera.isActive = false }
            if frame == 65 { camera.isActive = true }
        }
    }
}
