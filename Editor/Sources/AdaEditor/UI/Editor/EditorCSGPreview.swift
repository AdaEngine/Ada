@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

@Observable
@MainActor
final class EditorCSGPreview {
    enum Status: Equatable { case pending, ready, empty, failed }

    private(set) var status: [String: Status] = [:]
    var snapsToGrid = false
    @ObservationIgnored private var sources: [String: CSGGroupSource] = [:]
    @ObservationIgnored private var meshes: [String: Mesh3DComponent] = [:]
    @ObservationIgnored private var meshEntities: [String: Entity.ID] = [:]
    @ObservationIgnored private var rebuild: Task<Void, Never>?

    deinit { rebuild?.cancel() }

    func refresh(_ model: EditorSceneModel?, viewport: EditorSceneViewportModel) {
        guard viewport.world != nil else {
            return
        }
        let entities = model?.entities.filter { $0.components[EditorCSGScene.groupType] != nil } ?? []
        var snapshot: [String: CSGGroupSource] = [:]
        var statuses: [String: Status] = [:]
        let localIDs = Set(entities.map(\.id))
        var targets = viewport.csgTargets.filter { $0.key.contains("/") && !localIDs.contains($0.key) }.mapValues(\.source)
        for entity in entities {
            let source = try? model?.csgSource(entity, resourceRootURL: viewport.sceneResourceRootURL)
            targets.updateValue(source, forKey: entity.id)
        }
        for (id, source) in targets {
            snapshot[id] = source
            statuses[id] = source.map { sources[id] == $0 ? status[id] ?? .pending : .pending } ?? .failed
        }
        guard sources != snapshot || status != statuses else {
            return
        }
        sources = snapshot
        status = statuses
        meshes = meshes.filter { statuses[$0.key] != nil }
        let previous = rebuild
        previous?.cancel()
        let pending = snapshot.keys.sorted().compactMap { id -> (String, CSGGroupSource)? in
            guard statuses[id] == .pending, let source = snapshot[id] else {
                return nil
            }
            return (id, source)
        }
        rebuild = Task { [weak self, weak viewport] in
            await previous?.value
            do {
                try await Task.sleep(for: .milliseconds(45))
                for (id, source) in pending {
                    do {
                        let evaluated = try await source.evaluate()
                        guard let self, let viewport else {
                            return
                        }
                        try await viewport.withCSGWorldAccess {
                            try Task.checkCancellation()
                            if evaluated.isEmpty {
                                self.meshes[id] = nil
                                self.status[id] = .empty
                                if let child = self.meshEntities.removeValue(forKey: id) {
                                    viewport.world?.removeEntity(child, recursively: true)
                                }
                            } else if let device = unsafe RenderEngine.shared?.renderDevice,
                                let mesh = evaluated.renderComponent(renderDevice: device) {
                                self.meshes[id] = mesh
                                self.status[id] = .ready
                                self.install(mesh, for: id, in: viewport)
                            } else {
                                self.status[id] = .failed
                            }
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else {
                            return
                        }
                        self?.status[id] = .failed
                    }
                }
            } catch {
                return
            }
        }
    }

    func restore(in viewport: EditorSceneViewportModel) {
        for (id, mesh) in meshes {
            install(mesh, for: id, in: viewport)
        }
    }

    private func install(_ mesh: Mesh3DComponent, for id: String, in viewport: EditorSceneViewportModel) {
        guard let world = viewport.world, let owner = viewport.csgEntity(for: id) else {
            return
        }
        var ancestor: Entity? = owner
        var visited: Set<Entity.ID> = []
        while let entity = ancestor {
            guard entity.isActive, visited.insert(entity.id).inserted else {
                if let child = meshEntities.removeValue(forKey: id) {
                    world.removeEntity(child, recursively: true)
                }
                return
            }
            ancestor = entity.parent
        }
        if let childID = meshEntities[id], let child = world.getEntityByID(childID), child.parent?.id == owner.id {
            child.components[Mesh3DComponent.self] = mesh
        } else {
            let child = world.spawn("CSG Geometry") {
                Transform()
                mesh
            }
            owner.addChild(child)
            meshEntities[id] = child.id
        }
    }

    func pickingIDs(in viewport: EditorSceneViewportModel) -> [Entity.ID: String] {
        var result: [Entity.ID: String] = [:]
        for (groupID, meshID) in meshEntities {
            if let authoredID = viewport.csgEntity(for: groupID).flatMap({ viewport.authoredEditorID(for: $0.id) }) {
                result[meshID] = authoredID
            }
        }
        return result
    }

    func clear() {
        rebuild?.cancel()
        rebuild = nil
        status = [:]
        sources = [:]
        meshes = [:]
        meshEntities = [:]
    }
}

extension EditorSceneViewportModel {
    func drawSelectedCSGBox(in context: inout UIGraphicsContext, viewProjection: Transform3D, size: Size, theme: Theme) {
        guard displayMode == .threeD, let id = selectedEditorID,
            let operand = sceneModel?.entities.first(where: { $0.id == id && $0.components[EditorCSGScene.boxType] != nil }),
            let shape = EditorCSGScene.shape(of: operand),
            let matrix = gizmoWorldMatrix(for: id, respectingTransformGaps: true) else { return }
        var outline = Path()
        for loop in shape.outlineLoops() {
            let points = loop.map { project((matrix * Vector4($0, 1)).xyz, viewProjection: viewProjection, size: size) }
            let segmentCount = points.count == 2 ? 1 : points.count
            for index in 0..<segmentCount {
                guard let start = points[index], let end = points[(index + 1) % points.count] else { continue }
                outline.move(to: start)
                outline.addLine(to: end)
            }
        }
        context.stroke(outline, with: .black.opacity(0.75), style: StrokeStyle(lineWidth: 4))
        context.stroke(outline, with: theme.editorColors.blue, style: StrokeStyle(lineWidth: 2))
    }
}
