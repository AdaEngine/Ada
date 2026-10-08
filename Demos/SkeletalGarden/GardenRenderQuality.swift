import AdaEngine

@PlainSystem
struct GardenRenderQualitySystem {
    @Query<Ref<Environment3D>> private var cameras
    @Query<Ref<Camera>> private var temporalCameras
    @Res<Input> private var input
    @Local private var shadowsHeld = false
    @Local private var cascadesHeld = false
    @Local private var aoHeld = false
    @Local private var cullingHeld = false
    @Local private var lodHeld = false
    @Local private var aaHeld = false
    @Local private var temporalHeld = false
    @Local private var occlusionHeld = false

    init(world _: World) {}

    func update(context _: UpdateContext) {
        let shadows = input.isKeyPressed(.num1)
        let cascades = input.isKeyPressed(.num4)
        let ao = input.isKeyPressed(.num2)
        let culling = input.isKeyPressed(.num5)
        let lod = input.isKeyPressed(.num6)
        let aa = input.isKeyPressed(.num3)
        let temporal = input.isKeyPressed(.num7)
        let occlusion = input.isKeyPressed(.num0)
        if temporal, !temporalHeld {
            temporalCameras.forEach { camera in
                camera.temporalUpscaling = camera.temporalUpscaling == nil ? .init(renderScale: 0.75) : nil
                gardenLog("[SkeletalGarden] MetalFX Temporal=\(camera.temporalUpscaling != nil)")
            }
        }
        temporalHeld = temporal
        cameras.forEach { environment in
            if occlusion, !occlusionHeld { environment.meshVisibility.gpuOcclusion.toggle() }
            if shadows, !shadowsHeld {
                environment.shadows.isEnabled.toggle()
                gardenLog("[SkeletalGarden] shadows=\(environment.shadows.isEnabled)")
            }
            if cascades, !cascadesHeld {
                environment.shadows.cascadeCount = environment.shadows.cascadeCount == 1 ? 3 : 1
                gardenLog("[SkeletalGarden] shadow cascades=\(environment.shadows.cascadeCount)")
            }
            if ao, !aoHeld {
                environment.ambientOcclusion.isEnabled.toggle()
                gardenLog("[SkeletalGarden] SSAO=\(environment.ambientOcclusion.isEnabled)")
            }
            if culling, !cullingHeld { environment.meshVisibility.frustumCulling.toggle() }
            if lod, !lodHeld { environment.meshVisibility.lod.toggle() }
            if aa, !aaHeld {
                environment.antiAliasing = environment.antiAliasing == .none ? .fxaa : .none
                gardenLog("[SkeletalGarden] AA=\(environment.antiAliasing.rawValue)")
            }
        }
        occlusionHeld = occlusion
        cullingHeld = culling
        lodHeld = lod
        shadowsHeld = shadows
        cascadesHeld = cascades
        aoHeld = ao
        aaHeld = aa
    }
}
