import AdaEngine
import AdaEngineEmbeddable
import CompositorServices
import Foundation
import Observation

@Observable
@MainActor
final class GardenWorkspace {
    var isImmersed = false
    var isOpening = false
    var needsDismissal = false
    var selectionName: String?
    var selectedTransform: Transform?
    var isGrabbed = false
    var message: String?
    @ObservationIgnored private var renderer: AdaImmersiveRenderer?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var initialTransforms: [String: Transform] = [:]
    @ObservationIgnored private var hasPositionedScene = false

    func run(layer: LayerRenderer) async {
        guard renderer == nil else {
            return
        }
        isOpening = true
        let host = AdaImmersiveRenderer(layerRenderer: layer, assetBundle: .main)
        renderer = host
        hasPositionedScene = false
        host.onFrame = { [weak self] world in
            self?.positionSceneIfNeeded(world)
            self?.updateSelection(world)
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.renderer = nil
                self.renderTask = nil
                self.isImmersed = false
                self.isOpening = false
                self.selectionName = nil
                self.selectedTransform = nil
                self.isGrabbed = false
            }
            do {
                try await host.run { world in
                    try makeGarden(in: world, assetBundle: .main, includeCamera: false)
                    let device = unsafe RenderEngine.shared.renderDevice
                    arrangeGardenForImmersion(world, device: device)
                    let material = PBRMaterial()
                    material.baseColorFactor = [0.5, 0.28, 0.12, 1]
                    for (index, position) in [Vector3(-0.35, 1.4, 1.1), Vector3(0.35, 1.4, 1.1)].enumerated() {
                        world.spawn("Crate \(index + 1)") {
                            Mesh3DComponent(mesh: Mesh.generateCube(size: [0.25, 0.25, 0.25], renderDevice: device), materials: [material])
                            Transform(position: position)
                            SpatialGrabbable(halfExtents: [0.125, 0.125, 0.125])
                        }
                    }
                    if let sphere = world.getEntities().first(where: { $0.name == "Material Sphere" }) {
                        sphere.components[SpatialGrabbable.self] = SpatialGrabbable(halfExtents: [0.4, 0.4, 0.4])
                    }
                    self.initialTransforms = self.snapshot(world)
                    self.isOpening = false
                    self.isImmersed = true
                }
            } catch is CancellationError {
                // Normal immersive dismissal.
            } catch {
                self.needsDismissal = true
                self.message = "Garden stopped: \(error)"
                print("[ImmersiveGarden] \(self.message ?? "Unknown error")")
            }
        }
        renderTask = task
        await task.value
    }

    func stop() { renderTask?.cancel() }

    func scaleSelected(by factor: Float) {
        renderer?.performWorldAccess { world in
            guard let id = world.getResource(SpatialSelection.self)?.entityID,
                let entity = world.getEntities().first(where: { $0.id == id }),
                var transform = entity.components[Transform.self]
            else {
                return
            }
            let scale = transform.scale * factor
            guard scale.x >= 0.05, scale.y >= 0.05, scale.z >= 0.05,
                scale.x <= 10, scale.y <= 10, scale.z <= 10
            else {
                return
            }
            transform.scale = scale
            entity.components[Transform.self] = transform
        }
    }

    func save() {
        renderer?.performWorldAccess { [weak self] world in
            guard let self else {
                return
            }
            do {
                let document = GardenSceneDocument(transforms: snapshot(world))
                let url = try saveURL()
                try JSONEncoder().encode(document).write(to: url, options: .atomic)
                message = "Scene saved."
            } catch { message = "Save failed: \(error.localizedDescription)" }
        }
    }

    func load() {
        do {
            let document = try JSONDecoder().decode(GardenSceneDocument.self, from: Data(contentsOf: saveURL()))
            guard document.version == 1, document.transforms.values.allSatisfy(Self.isValid) else {
                message = "The saved scene contains unsupported or invalid transforms."
                return
            }
            renderer?.performWorldAccess { [weak self] world in
                self?.apply(document.transforms, to: world)
                self?.message = "Scene loaded."
            }
        } catch { message = "Load failed: \(error.localizedDescription)" }
    }

    func reset() {
        renderer?.performWorldAccess { [weak self] world in
            guard let self else {
                return
            }
            apply(initialTransforms, to: world)
            message = "Objects reset."
        }
    }

    private func arrangeGardenForImmersion(_ world: World, device: RenderDevice) {
        var pillarIndex = 0
        for entity in world.getEntities() where entity.parent == nil {
            guard var transform = entity.components[Transform.self] else { continue }
            if entity.components[GardenPlayer.self] != nil {
                transform.position = [-1.1, 0, 4.5]
            } else if let animation = entity.components[ModelAnimation3DComponent.self] {
                transform.position = animation.player.clips.contains(where: { $0.name == "Bend" }) ? [-2, 0.2, 4] : [1.1, 0, 4.5]
            } else if entity.name == "Material Sphere" {
                transform.position = [1.2, 1.25, 2.5]
            } else if entity.name == "Ground", var mesh = entity.components[Mesh3DComponent.self] {
                mesh.mesh = Mesh.generatePlane(size: [24, 24], renderDevice: device)
                entity.components[Mesh3DComponent.self] = mesh
            } else if entity.name == "Pillar" {
                let side: Float = pillarIndex.isMultiple(of: 2) ? -1 : 1
                transform.position = [side * 2.5, 0.65, pillarIndex < 2 ? -3 : 5]
                pillarIndex += 1
            }
            entity.components[Transform.self] = transform
        }
    }

    private func positionSceneIfNeeded(_ world: World) {
        guard !hasPositionedScene,
            let eye = world.getEntities().first(where: { $0.components[Camera.self] != nil }),
            let pose = eye.components[Transform.self]
        else { return }
        // The tracking origin is not necessarily the floor. Place this demo around
        // the initial head pose, with a nominal standing eye height of 1.6 meters.
        let forward = pose.matrix.z.xyz
        let yaw = Math.atan2(forward.x, forward.z)
        let rotation = Quat(axis: .up, angle: yaw)
        let placement = Transform3D(translation: pose.position - [0, 1.6, 0], rotation: rotation, scale: .one)
        for entity in world.getEntities() where entity.parent == nil && entity.components[Camera.self] == nil {
            guard var transform = entity.components[Transform.self] else { continue }
            transform.position = (placement * Vector4(transform.position, 1)).xyz
            transform.rotation = (Transform3D(quat: rotation) * Transform3D(quat: transform.rotation)).rotation
            entity.components[Transform.self] = transform
        }
        initialTransforms = snapshot(world)
        hasPositionedScene = true
        print("[ImmersiveGarden] positioned around head \(pose.position), yaw=\(yaw)")
    }

    private func updateSelection(_ world: World) {
        let selection = world.getResource(SpatialSelection.self)
        let entity = world.getEntities().first { $0.id == selection?.entityID }
        selectionName = entity?.name
        selectedTransform = entity?.components[Transform.self]
        isGrabbed = selection?.isGrabbed ?? false
    }

    private func snapshot(_ world: World) -> [String: Transform] {
        var result: [String: Transform] = [:]
        for entity in world.getEntities() where entity.components[SpatialGrabbable.self] != nil {
            if let transform = entity.components[Transform.self] { result[entity.name] = transform }
        }
        return result
    }

    private func apply(_ transforms: [String: Transform], to world: World) {
        for entity in world.getEntities() where entity.components[SpatialGrabbable.self] != nil {
            if let transform = transforms[entity.name] { entity.components[Transform.self] = transform }
        }
    }

    private func saveURL() throws -> URL {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("ImmersiveGarden.scene.json")
    }

    private static func isValid(_ transform: Transform) -> Bool {
        let matrix = transform.matrix
        return abs(transform.rotation.dot(transform.rotation) - 1) < 0.02
            && (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column, $0].isFinite } }
            && transform.scale.x >= 0.05 && transform.scale.y >= 0.05 && transform.scale.z >= 0.05
            && transform.scale.x <= 10 && transform.scale.y <= 10 && transform.scale.z <= 10
    }
}

private struct GardenSceneDocument: Codable {
    var version = 1
    var transforms: [String: Transform]
}
