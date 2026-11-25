@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Observation

@MainActor
@Observable
final class EditorDecalEditing {
    struct Preview {
        let hit: EditorMeshPicking.DecalHit
        let frame: Transform3D
        let rotationDegrees: Float
        let size: Vector3
    }

    static let componentType = String(reflecting: Decal3DSource.self)
    private(set) var enabled = false
    private(set) var isPlacing = false
    private(set) var isApplying = false
    private(set) var ownerID: String?
    private(set) var entries: [Decal3DSource.Entry] = []
    var selection: UUID?
    var draftImage = ""
    var message: String?
    @ObservationIgnored private(set) var preview: Preview?
    @ObservationIgnored private var moved: UUID?
    @ObservationIgnored private var pointerDown: Point?
    @ObservationIgnored private var applyingTask: Task<Void, Never>?

    var selectedEntry: Decal3DSource.Entry? { entries.first { $0.id == selection } }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else {
            return
        }
        cancel()
        self.enabled = enabled
    }

    func sync(ownerID: String?, model: EditorSceneModel?) {
        let updated = ownerID.flatMap { owner in
            model?.entities.first { $0.id == owner }.flatMap(Self.source)
        }?.entries ?? []
        guard self.ownerID != ownerID || entries != updated else {
            return
        }
        if self.ownerID != ownerID {
            if moved != nil { cancel() }
            selection = nil
        }
        self.ownerID = ownerID
        entries = updated
        if selectedEntry == nil { selection = updated.first?.id }
    }

    func begin(move: Bool = false) {
        guard enabled, !isApplying, move ? selectedEntry != nil : !draftImage.isEmpty else {
            return
        }
        cancel()
        moved = move ? selection : nil
        isPlacing = true
    }

    func cancel() {
        applyingTask?.cancel()
        applyingTask = nil
        isApplying = false
        isPlacing = false
        moved = nil
        pointerDown = nil
        preview = nil
        message = nil
    }

    func updatePointer(_ event: MouseEvent, viewport: EditorSceneViewportModel) -> Bool {
        guard !isApplying else {
            return true
        }
        if event.phase == .cancelled {
            pointerDown = nil
            preview = nil
            return true
        }
        if event.phase == .began, event.button == .left { pointerDown = event.mousePosition }
        updatePreview(at: event.mousePosition, viewport: viewport)
        if event.phase == .ended, event.button == .left {
            if let pointerDown {
                let offset = Vector2(event.mousePosition.x - pointerDown.x, event.mousePosition.y - pointerDown.y)
                if offset.squaredLength < 16 { commit(viewport) }
            }
            pointerDown = nil
        }
        return true
    }

    private func updatePreview(at point: Point, viewport: EditorSceneViewportModel) {
        guard let hit = viewport.decalSurface(at: point), moved == nil || hit.editorID == ownerID,
              let frame = Decal3D.Projector.surfaceFrame(point: hit.point, normal: hit.normal) else {
            preview = nil
            if message != "Choose an opaque 3D surface." { message = "Choose an opaque 3D surface." }
            return
        }
        let moving = moved == nil ? nil : selectedEntry
        preview = Preview(hit: hit, frame: frame, rotationDegrees: moving?.rotationDegrees ?? 0, size: moving?.size ?? Vector3(0.45, 0.45, 0.10))
        if message != nil { message = nil }
    }

    func commit(_ viewport: EditorSceneViewportModel) {
        guard !isApplying, let preview else {
            return
        }
        let owner = preview.hit.editorID
        let local = preview.hit.matrix.inverse * preview.frame
        let node: Decal3DSource.ModelNode?
        if var imported = preview.hit.node {
            guard let authored = viewport.sceneModel?.entities.first(where: { $0.id == owner }),
                  let reference = authored.components[EditorBuiltInComponentType.model3DSource]?["source"]?.stringValue,
                  let path = Self.portableReference(reference, viewport: viewport) else {
                message = "The model must be inside project assets."
                return
            }
            imported.source = path
            node = imported
        } else { node = nil }

        if let moved {
            guard var entry = selectedEntry, moved == entry.id, node == entry.node else {
                message = "Choose a surface on the same mesh."
                return
            }
            entry.localFrame = local
            _ = replace(entry, viewport: viewport, finishPlacement: true)
        } else {
            guard let model = viewport.sceneModel?.entities.first(where: { $0.id == owner }) else {
                return
            }
            var source = Self.source(model) ?? .init()
            guard source.entries.lazy.filter({ $0.node == node }).count < 8, source.entries.count < 64 else {
                message = "This object has reached its decal limit."
                return
            }
            let entry = Decal3DSource.Entry(node: node, localFrame: local, size: preview.size, images: .init(color: draftImage))
            source.entries.append(entry)
            _ = apply(source, to: owner, edit: entry, viewport: viewport)
        }
    }

    @discardableResult
    func replace(_ entry: Decal3DSource.Entry, viewport: EditorSceneViewportModel, finishPlacement: Bool = false) -> Bool {
        guard let ownerID, let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return false
        }
        var source = Decal3DSource(entries: entries)
        source.entries[index] = entry
        guard source.entries.lazy.filter({ $0.node == entry.node }).count <= 8 else {
            message = "This object has reached its decal limit."
            return false
        }
        return apply(source, to: ownerID, edit: entry, viewport: viewport, finishPlacement: finishPlacement)
    }

    func deleteSelected(viewport: EditorSceneViewportModel) {
        guard let ownerID, let selection else {
            return
        }
        let source = Decal3DSource(entries: entries.filter { $0.id != selection })
        _ = apply(source, to: ownerID, edit: nil, viewport: viewport, finishPlacement: true)
    }

    func selectedError(in viewport: EditorSceneViewportModel) -> String? {
        guard let ownerID, let selection, let id = viewport.entitiesByEditorID[ownerID],
              let error = viewport.world?.getResource(Decal3DSourceStatus.self)?.error(for: id, entry: selection) else { return nil }
        switch error {
        case "assetLoadFailed": return "Could not load the decal images."
        case "missingReceiver": return "The decal target is missing or has changed."
        case "capacityExceeded": return "This object has reached its decal limit."
        default: return "The decal could not be placed on this surface."
        }
    }

    private func apply(
        _ source: Decal3DSource,
        to owner: String,
        edit: Decal3DSource.Entry?,
        viewport: EditorSceneViewportModel,
        finishPlacement: Bool = false
    ) -> Bool {
        guard !isApplying, let world = viewport.world,
              let current = viewport.sceneModel?.entities.first(where: { $0.id == owner }) else { return false }
        let previous = current.components[Self.componentType]
        let selectionAtStart = viewport.selectedEditorID
        isApplying = true
        applyingTask = Task { @MainActor [weak self, weak viewport, weak world] in
            guard let self, let viewport, let world else {
                return
            }
            defer {
                if !Task.isCancelled {
                    self.isApplying = false
                    self.applyingTask = nil
                }
            }
            do {
                let appearance = if let edit { try await viewport.loadDecalImages(edit.images) } else { nil as Decal3D.Appearance? }
                try await viewport.withDecalWorldAccess {
                    try Task.checkCancellation()
                    guard viewport.world === world, let entity = viewport.runtimeEntity(for: owner),
                          var model = viewport.sceneModel, let index = model.entities.firstIndex(where: { $0.id == owner }),
                          model.entities[index].components[Self.componentType] == previous else { return }
                    if source.entries.isEmpty {
                        model.entities[index].components.removeValue(forKey: Self.componentType)
                    } else {
                        let data = try JSONEncoder().encode(source)
                        model.entities[index].components[Self.componentType] = try JSONDecoder().decode(EditorComponentPayload.self, from: data)
                    }
                    let shouldSelectReceiver = viewport.selectedEditorID == selectionAtStart
                    if shouldSelectReceiver { model.selectEntity(owner) }
                    let content = try model.encodedYAML()
                    if let edit, let appearance, let order = source.entries.firstIndex(where: { $0.id == edit.id }) {
                        guard let status = world.getResource(Decal3DSourceStatus.self) else { throw Decal3D.PlacementError.unsupportedBackend }
                        try status.applyEdit(edit, order: order, on: entity, appearance: appearance)
                    }
                    entity.components[Decal3DSource.self] = source.entries.isEmpty ? nil : source
                    viewport.sceneModel = model
                    viewport.sceneContent = content
                    if shouldSelectReceiver {
                        viewport.selectedEditorID = owner
                        if let edit { self.selection = edit.id }
                    }
                    self.message = nil
                    viewport.publishDecalEdit(content)
                }
                if finishPlacement, !Task.isCancelled { self.cancel() }
            } catch is CancellationError {
                return
            } catch let error as Decal3D.PlacementError {
                if !Task.isCancelled {
                    self.message = error == .capacityExceeded ? "This object has reached its decal limit."
                        : "The decal could not be placed on this surface."
                }
            } catch {
                if !Task.isCancelled { self.message = "Could not load the decal images." }
            }
        }
        return true
    }

    static func source(_ entity: EditorSceneEntity) -> Decal3DSource? {
        guard let payload = entity.components[componentType], let data = try? JSONEncoder().encode(EditorSceneValue.object(payload)) else {
            return nil
        }
        return try? JSONDecoder().decode(Decal3DSource.self, from: data)
    }

    private static func portableReference(_ reference: String, viewport: EditorSceneViewportModel) -> String? {
        if reference.hasPrefix("@res://") {
            return reference
        }
        guard let root = viewport.sceneResourceRootURL,
              let url = EditorSceneFileLoader.resolveTileMapReference(
                reference, relativeTo: viewport.sceneSourceURL, resourceRootURL: root, fileExtension: URL(fileURLWithPath: reference).pathExtension
              ) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.path.hasPrefix(base) else {
            return nil
        }
        return "@res://" + String(url.path.dropFirst(base.count))
    }
}
