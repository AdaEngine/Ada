import AdaEngine

enum GardenLightingMode {
    static func usesLocalLights(arguments: [String]) -> Bool {
        arguments.contains("--local-lights") || !arguments.contains("--daylight")
    }
}

struct GardenLocalLight: Component {
    var origin: Vector3
    var moves: Bool = false
}

@MainActor
func addGardenLocalLighting(in world: World) {
    let args = ProcessInfo.processInfo.arguments
    guard GardenLightingMode.usesLocalLights(arguments: args) else {
        return
    }
    let disabled = args.contains("--no-local-lights")
    let pointOnly = args.contains("--point-only")
    let spotOnly = args.contains("--spot-only")
    let first = world.spawn("Lantern Point Light") {
        PointLightComponent(radiance: [1, 0.35, 0.08], intensity: disabled || spotOnly ? 0 : 45, range: 9, shadowPriority: 2)
        Transform(position: [3.1, 2.4, 0.5])
        GardenLocalLight(origin: [3.1, 2.4, 0.5], moves: true)
    }
    _ = first
    world.spawn("Courtyard Cool Point Light") {
        PointLightComponent(radiance: [0.1, 0.35, 1], intensity: disabled || pointOnly || spotOnly ? 0 : 32, range: 8)
        Transform(position: [-2.8, 2.8, 2.5])
        GardenLocalLight(origin: [-2.8, 2.8, 2.5])
    }
    let spotPosition = Vector3(-1, 6, -1.5)
    let direction = (Vector3(0.3, 0, 0.8) - spotPosition).normalized
    world.spawn("Garden Spot Light") {
        SpotLightComponent(radiance: [0.3, 1, 0.4], intensity: disabled || pointOnly ? 0 : 160, range: 12, innerConeAngle: 16, outerConeAngle: 28, shadowPriority: 5)
        Transform(matrix: LocalLighting3DMath.view(position: spotPosition, direction: direction).inverse)
        GardenLocalLight(origin: spotPosition)
    }
    world.spawn("Cool Fill Directional") {
        DirectionalLightComponent(radiance: [0.3, 0.4, 0.8], intensity: 0.2, castShadows: false)
        Transform(rotation: Quat(axis: .right, angle: -0.7))
    }
    if args.contains("--many-local-lights") {
        for index in 0..<40 {
            world.spawn("Budget Point \(index)") {
                PointLightComponent(radiance: [0.25, 0.18, 0.12], intensity: 1, range: 9)
                Transform(position: [Float(index % 8) - 3.5, 2.5, Float(index / 8) - 2])
            }
        }
    }
}

@PlainSystem(dependencies: [.before(TransformSystem.self)])
struct GardenLocalLightingSystem {
    @Query<GardenLocalLight, Ref<Transform>> private var lamps
    @Query<GardenLocalLight, Ref<PointLightComponent>> private var points
    @Query<GardenLocalLight, Ref<SpotLightComponent>> private var spots
    @Query<Ref<Environment3D>> private var environments
    @Res<Input> private var input
    @Local private var frame = 0
    @Local private var lightHeld = false
    @Local private var shadowHeld = false
    @Local private var enabled = true
    private let moving = ProcessInfo.processInfo.arguments.contains("--local-motion")

    init(world _: World) {}

    func update(context _: UpdateContext) {
        frame += 1
        if moving {
            lamps.forEach { lamp, transform in
                if lamp.moves { transform.position = lamp.origin + [Math.sin(Float(frame) * 0.025), 0, 0] }
            }
        }
        let toggle = input.isKeyPressed(.num8)
        let shadows = input.isKeyPressed(.num9)
        if toggle, !lightHeld {
            enabled.toggle()
            points.forEach { lamp, light in light.intensity = enabled ? (lamp.moves ? 45 : 32) : 0 }
            spots.forEach { _, light in light.intensity = enabled ? 160 : 0 }
        }
        if shadows, !shadowHeld { environments.forEach { $0.localShadows.isEnabled.toggle() } }
        lightHeld = toggle
        shadowHeld = shadows
    }
}
