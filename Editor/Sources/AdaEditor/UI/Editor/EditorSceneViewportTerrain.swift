@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

enum EditorTerrainCreationBackend: String, CaseIterable {
    case heightfield = "Heightfield"
    case mesh = "Mesh Terrain"
}

struct EditorMeshTerrainTarget: Equatable, Identifiable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class EditorTerrainEditingState {
    var creationBackend: EditorTerrainCreationBackend = .mesh
    var isSourceBusy = false
    var sourceStatus: String?
    var sourceFailure: String?
    var meshTargetEditorID: String?
    var meshTargets: [EditorMeshTerrainTarget] = []
    var meshSourceName: String?
    var meshHasBinding = false
    @ObservationIgnored var meshControlsTask: Task<Void, Never>?
    @ObservationIgnored var meshControlsGeneration = UUID()
    @ObservationIgnored var meshControlsBinding: MeshTerrain3DBinding?
    @ObservationIgnored var meshSourceEditorID: String?
    @ObservationIgnored var meshPoseQueue = EditorMeshTerrainPoseQueue()
    @ObservationIgnored var meshDragSession: EditorMeshTerrainDragSession?
    @ObservationIgnored var meshGroupDrag: EditorMeshTerrainGroupDrag?
    @ObservationIgnored var meshHistoryQueue = EditorMeshTerrainHistoryQueue()
    @ObservationIgnored var meshSculptPointerActive = false
    @ObservationIgnored var meshBrushPoints: [Point] = []
    @ObservationIgnored var meshBrushLastPoint: Point?
    @ObservationIgnored var meshSculptStroke: EditorMeshTerrainSculptStroke?
    var meshSelectedParts: [MeshTerrainPartSelection] = []
    var meshOperation = "Join"
    var meshContactWidth: Float = 1
    var meshConformDistance: Float = 2
    var meshConformStrength: Float = 1
    @ObservationIgnored var brushRevision: UInt64 = 0
    var sourceTool: EditorTerrainTool = .sculpt
    var dockTab = "Sculpt"
    var sourceAssetFolder: URL?
    var sourcePresetName = ""
    var sourceManifest: TerrainManifestAsset?
    var sourceLayerID: UInt16 = 0
    var sourcePrototypeID: UInt16 = 0
    var meshReference = ""
    var textureReference = ""
    var volumeOperand = "Sphere"
    var meshDensity: Double = 0.15
    var usesTextureVariation = true
    var noise = EditorTerrainNoise()
    @ObservationIgnored var sourceActions: EditorTerrainSourceActions?
    @ObservationIgnored var sourceStroke: SourceStroke?
    @ObservationIgnored var sourceTask: Task<Void, Never>?
    @ObservationIgnored var sourceHoverTask: Task<Void, Never>?
    @ObservationIgnored var sourceGeneration = UUID()
    @ObservationIgnored var sourceReleaseRequested = false
    var isEnabled = false
    /// Object joining uses the ordinary selection/transform interaction inside the terrain dock.
    var usesBrush: Bool { isEnabled && dockTab != "Joining" }
    var mode: EditorTerrainBrushMode = .raise
    var radius: Float = 4
    var strength: Float = 3
    @ObservationIgnored var pointer: Point?
    @ObservationIgnored var hover: Hit?
    @ObservationIgnored var stroke: Stroke?

    struct Hit {
        var editorID: String
        var point: Vector3
        var matrix: Transform3D
        var storage: TerrainHeightStorage?
        var queries: TerrainSurfaceQueries?
    }

    struct Stroke {
        var editorID: String
        var original: Terrain3D
        var flattenHeight: Float
        var previousPoint: Vector3
    }
}

extension EditorSceneViewportModel {
    func setTerrainEditing(_ enabled: Bool) {
        endTerrainStroke(cancelled: true)
        endTransformDrag(cancelled: true)
        terrainEditing.isEnabled = enabled
        terrainEditing.hover = nil
        if enabled {
            setDisplayMode(.threeD)
            refreshTerrainSourceControls()
        } else {
            refreshMeshTerrainControls()
        }
    }

    func createTerrain() {
        endTerrainStroke()
        guard var model = sceneModel else {
            return
        }
        let id = model.addEntity(name: L10n.text("Terrain"), parentID: nil).id
        model.addComponent(typeName: EditorBuiltInComponentType.visibility, to: id)
        guard let index = model.entities.firstIndex(where: { $0.id == id }) else {
            return
        }
        model.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(Terrain3D())
        model.editor?.selectedEntity = id
        sceneModel = model
        selectedEditorID = id
        publishTerrainDocument()
        _ = reloadSceneRuntimeIfReady()
        onSelectionChanged?(selectedEntityViewModel(editorID: id, model: model))
    }

    func handleTerrainPointer(at position: Point, began: Bool = false, ended: Bool = false, cancelled: Bool = false) -> Bool {
        guard terrainEditing.usesBrush, displayMode == .threeD else {
            return false
        }
        terrainEditing.pointer = position
        if terrainEditing.meshSculptPointerActive || (terrainEditing.stroke == nil && terrainEditing.sourceStroke == nil && isMeshTerrainSource(for: selectedEditorID)) {
            return handleMeshTerrainSculptPointer(at: position, began: began, ended: ended, cancelled: cancelled)
        }
        if handleSourceTerrainPointer(at: position, began: began, ended: ended, cancelled: cancelled) {
            return true
        }
        return handleLegacyTerrainPointer(at: position, began: began, ended: ended, cancelled: cancelled)
    }

    func handleLegacyTerrainPointer(at position: Point, began: Bool = false, ended: Bool = false, cancelled: Bool = false) -> Bool {
        terrainEditing.hover = terrainHit(at: position, lockedTo: terrainEditing.stroke?.editorID)
        if cancelled {
            endTerrainStroke(cancelled: true)
            return true
        }
        if ended {
            endTerrainStroke()
            return true
        }
        if began, let hit = terrainEditing.hover,
           let payload = sceneModel?.entities.first(where: { $0.id == hit.editorID })?.components[EditorTerrainPayload.typeName],
           let terrain = EditorTerrainPayload.decode(payload) {
            selectedEditorID = hit.editorID
            sceneModel?.editor?.selectedEntity = hit.editorID
            terrainEditing.stroke = .init(editorID: hit.editorID, original: terrain, flattenHeight: hit.point.y, previousPoint: hit.point)
            _ = updateTerrainStroke(deltaTime: 1 / 60)
        }
        return true
    }

    func updateTerrainStroke(deltaTime: Float) -> Bool {
        if terrainEditing.meshSculptStroke != nil { return updateMeshTerrainSculpt(deltaTime: deltaTime) }
        if terrainEditing.sourceStroke != nil {
            return updateSourceTerrainStroke(deltaTime: deltaTime)
        }
        guard var stroke = terrainEditing.stroke, let pointer = terrainEditing.pointer,
              let hit = terrainHit(at: pointer, lockedTo: stroke.editorID),
              let payload = sceneModel?.entities.first(where: { $0.id == stroke.editorID })?.components[EditorTerrainPayload.typeName],
              var terrain = EditorTerrainPayload.decode(payload) else {
            return false
        }
        terrainEditing.hover = hit
        // Resample fast pointer movement so a brush stroke stays continuous.
        let distance = (hit.point - stroke.previousPoint).length
        guard distance.isFinite else {
            return false
        }
        let samples = min(128, max(1, Int(ceil(distance / max(0.05, terrainEditing.radius * 0.25)))))
        for sample in 1...samples {
            let point = stroke.previousPoint + (hit.point - stroke.previousPoint) * (Float(sample) / Float(samples))
            EditorTerrainBrush.apply(
                to: &terrain,
                at: point,
                mode: terrainEditing.mode,
                radius: terrainEditing.radius,
                strength: terrainEditing.strength,
                duration: min(deltaTime, 0.05) / Float(samples),
                flattenHeight: stroke.flattenHeight
            )
        }
        stroke.previousPoint = hit.point
        terrainEditing.stroke = stroke
        applyTerrain(terrain, editorID: stroke.editorID)
        return true
    }

    func endTerrainStroke(cancelled: Bool = false) {
        endSourceTerrainStroke(cancelled: cancelled)
        guard let stroke = terrainEditing.stroke else {
            return
        }
        terrainEditing.stroke = nil
        if cancelled {
            applyTerrain(stroke.original, editorID: stroke.editorID)
        } else if let payload = sceneModel?.entities.first(where: { $0.id == stroke.editorID })?.components[EditorTerrainPayload.typeName],
                  EditorTerrainPayload.decode(payload) != stroke.original {
            publishTerrainDocument()
        }
        if let model = sceneModel { onSelectionChanged?(selectedEntityViewModel(editorID: stroke.editorID, model: model)) }
    }

    private func applyTerrain(_ terrain: Terrain3D, editorID: String) {
        guard let index = sceneModel?.entities.firstIndex(where: { $0.id == editorID }) else {
            return
        }
        sceneModel?.entities[index].components[EditorTerrainPayload.typeName] = EditorTerrainPayload.encode(terrain)
        if let runtimeID = entitiesByEditorID[editorID], let entity = world?.getEntityByID(runtimeID) {
            entity.components[Terrain3D.self] = terrain
        }
    }

    func publishTerrainDocument() {
        guard let model = sceneModel, let content = try? model.encodedYAML() else {
            return
        }
        sceneContent = content
        onDocumentContentChanged?(content)
    }

    func terrainHit(at point: Point, lockedTo editorID: String?) -> EditorTerrainEditingState.Hit? {
        guard !isPerspectiveTransitionActive, let model = sceneModel else {
            return nil
        }
        let camera = cameraState(for: viewportSize)
        guard let ray = EditorPicking.ray(
            point: point,
            viewportSize: viewportSize,
            cameraTransform: camera.transform.matrix,
            projection: camera.projection.makeClipView()
        ) else {
            return nil
        }
        var nearest = Float.infinity
        var result: EditorTerrainEditingState.Hit?
        for entity in model.entities where editorID == nil || entity.id == editorID {
            guard entity.enabled, let payload = entity.components[EditorTerrainPayload.typeName],
                  let terrain = EditorTerrainPayload.decode(payload), let matrix = gizmoWorldMatrix(for: entity.id),
                  let local = EditorPicking.localRay(ray, matrix: matrix),
                  let hit = EditorTerrainBrush.hit(ray: local, terrain: terrain), hit.distance < nearest else { continue }
            nearest = hit.distance
            result = .init(editorID: entity.id, point: hit.point, matrix: matrix)
        }
        return result
    }

    func drawTerrainBrush(in context: inout UIGraphicsContext, size: Size, theme: Theme) {
        guard terrainEditing.usesBrush, displayMode == .threeD, let hit = terrainEditing.hover else {
            return
        }
        let terrain = sceneModel?.entities.first(where: { $0.id == hit.editorID })?.components[EditorTerrainPayload.typeName].flatMap(EditorTerrainPayload.decode)
        guard terrain != nil || hit.storage != nil || hit.queries != nil else {
            return
        }
        let normal = (try? hit.queries?.closest(to: hit.point, maximumWork: 32_768))?.normal ?? Vector3(0, 1, 0)
        let tangent = normal.cross(abs(normal.y) < 0.9 ? Vector3(0, 1, 0) : Vector3(1, 0, 0)).normalized
        let bitangent = normal.cross(tangent).normalized
        for segment in 0..<48 {
            func point(_ index: Int) -> Vector3 {
                let angle = Float(index) / 48 * Float.pi * 2
                let offsetX = Math.cos(angle) * terrainEditing.radius
                let offsetZ = Math.sin(angle) * terrainEditing.radius
                var local = hit.point + tangent * offsetX + bitangent * offsetZ
                if let sample = try? hit.queries?.closest(to: local, maximumDistance: max(1, terrainEditing.radius * 2), maximumWork: 32_768) {
                    local = sample.position + sample.normal * 0.04
                } else {
                    local.y = (hit.storage?.height(at: Vector2(local.x, local.z)) ?? terrain?.surfaceHeight(at: Vector2(local.x, local.z)) ?? hit.point.y) + 0.04
                }
                return (hit.matrix * Vector4(local, 1)).xyz
            }
            drawProjectedSegment(from: point(segment), to: point(segment + 1), in: &context, size: size, lineWidth: 3, color: theme.editorColors.blue)
        }
    }
}
