import AdaEngine
import AdaEngineEmbeddable
import Foundation
import Observation

/// Shared editor document/Inspector state. The visionOS host supplies runtime access at frame boundaries.
@Observable
@MainActor
final class EditorVRWorkspace {
    let workbench = EditorWorkbenchViewModel(openDocuments: [], activeDocumentID: "")
    let inspector = EditorInspectorSidebarViewModel(transformFields: [], scriptName: "", scriptDescription: "")
    let viewport = EditorSceneViewportModel()
    var project: EditorProjectReference?
    var studio: EditorViewModel?
    private(set) var playSession: EditorVRPlaySession?
    private(set) var settingsWindow: EditorSettingsWindowViewModel?
    private(set) var voiceDraft: EditorVRVoiceDraft?
    private var sceneDocumentID: String?
    var projectURL: URL?
    var resourceRootURL: URL?
    var scenes: [URL] = []
    var message: String?
    var isImmersed = false
    var isOpening = false
    var isManipulating = false
    var isNavigating = false
    private var textInputHosts: Set<String> = []
    private var hoveredPanels: Set<EditorVRPanel> = []
    var isEditingText: Bool { !textInputHosts.isEmpty }
    var isPointerOverPanel: Bool { !hoveredPanels.isEmpty }
    func setTextInputFocus(_ focused: Bool, host: String) {
        if focused { textInputHosts.insert(host) } else { textInputHosts.remove(host) }
    }
    func setPanelHover(_ hovered: Bool, panel: EditorVRPanel) {
        if hovered { hoveredPanels.insert(panel) } else { hoveredPanels.remove(panel) }
    }
    @ObservationIgnored private let navigation = EditorVRNavigationController()
    private(set) var activeTool: EditorSceneViewportTool = .translate
    var presentedPanels: Set<EditorVRPanel> = []
    private(set) var modelAssets: [EditorAssetDocument] = []
    private(set) var saveFailure: String?
    @ObservationIgnored var runtimeAccess: ((@escaping @MainActor (World) -> Void) -> Void)?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private let palmWheel = EditorVRPalmWheel()
    var activatedPalmPanel: EditorVRPanel?
    private(set) var isPalmMenuVisible = false
    @ObservationIgnored private let gizmo = EditorVRGizmoController()
    @ObservationIgnored private var boundsRefreshes = 0
    @ObservationIgnored private var store: EditorProjectStore

    init(store: EditorProjectStore = EditorProjectStore()) {
        self.store = store
        recentProjects = (try? store.loadProjects()) ?? []
        EditorComponentRegistry.registerBuiltIns()
        workbench.setActiveDocumentChangedHandler { [weak self] in self?.synchronizeDocument() }
        inspector.setSceneViewportActions(
            owner: self,
            applyGizmoChange: { [weak self] value in self?.edit { self?.viewport.updateSelectedGizmo(value) } },
            addEntity: { [weak self] preset in self?.addEntity(preset: preset) },
            addComponent: { [weak self] type in
                self?.edit {
                    self?.modifyDocument { model in
                        if let id = model.editor?.selectedEntity { model.addComponent(typeName: type, to: id) }
                    }
                }
            },
            removeComponent: { [weak self] type in
                self?.edit {
                    self?.modifyDocument { model in
                        if let id = model.editor?.selectedEntity { model.removeComponent(typeName: type, from: id) }
                    }
                }
            },
            updateComponentField: { [weak self] type, field, value in
                self?.edit {
                    guard let self, let document = self.document else {
                        return
                    }
                    self.workbench.updateComponentField(typeName: type, field: field, value: value, inSelectedEntityOf: document.id)
                }
            },
            addScriptableObject: { [weak self] descriptor in
                self?.edit {
                    self?.modifyDocument { model in
                        if let id = model.editor?.selectedEntity { model.addScriptableObject(descriptor, to: id) }
                    }
                }
            },
            removeScriptableObject: { [weak self] identifier in
                self?.edit {
                    self?.modifyDocument { model in
                        if let id = model.editor?.selectedEntity { model.removeScriptableObject(identifier: identifier, from: id) }
                    }
                }
            },
            updateScriptableObjectField: { [weak self] identifier, field, value in
                self?.edit {
                    self?.modifyDocument { model in
                        if let id = model.editor?.selectedEntity { model.updateScriptableObjectField(identifier: identifier, field: field, value: value, in: id) }
                    }
                }
            }
        )
    }

    private func connectStudio(_ reference: EditorProjectReference) {
        let editor = EditorViewModel(project: reference, workbench: workbench)
        studio = editor
        editor.nativeAdaScriptLauncher = { [weak self] artifact, title in
            guard let self else { throw EditorAdaScriptRuntimeError.windowManagerUnavailable }
            try self.startPlay(artifact: artifact, title: title)
        }
        editor.nativeAdaScriptStopper = { [weak self] in self?.stopPlay() }
        settingsWindow = nil
        voiceDraft = EditorVRVoiceDraft(agent: editor.agent)
        let changed = workbench.onActiveDocumentChanged
        let edited = workbench.onDocumentEdited
        workbench.setActiveDocumentChangedHandler { [weak self] in
            changed?()
            if let self, !self.isImmersed, let active = self.workbench.activeSceneDocument { self.sceneDocumentID = active.id }
            self?.synchronizeDocument()
        }
        workbench.setDocumentEditedHandler { [weak self] id in
            if self?.studio?.didStartEditorSession == true { edited?(id) }
            guard let self, id == self.document?.id else {
                return
            }
            self.synchronizeDocument()
        }
    }

    func startPlay(artifact: EditorAdaScriptProjectBuildArtifact, title: String) throws {
        let next = try EditorVRPlaySession(artifact: artifact, title: title)
        stopPlay()
        playSession = next
        studio?.adaScriptRuntimeControls = next.controls
    }

    func stopPlay(id: UUID? = nil) {
        guard let playSession, id == nil || id == playSession.id else {
            return
        }
        playSession.runtime.performanceSession.stop()
        playSession.controls.finish()
        self.playSession = nil
        studio?.adaScriptRuntimeControls = nil
        studio?.adaScriptHotReloadTask?.cancel()
        studio?.workspaceStatus = .ready
        studio?.footer.setWorkspaceFooterTitle("Workspace: Ready")
        studio?.appendOutput("Stopped AdaScript project \(playSession.title).")
    }

    /// Consumes the shared editor's Settings request without presenting a cover over Studio.
    @discardableResult
    func prepareSettingsWindow() -> Bool {
        guard let editor = studio else {
            return false
        }
        let section = editor.requestedSettingsSection ?? settingsWindow?.selectedSection ?? .general
        if let settingsWindow {
            settingsWindow.selectedSection = section
            if let page = editor.requestedSettingsPage, settingsWindow.pages(in: section).contains(page) {
                settingsWindow.selectedPage = page
            }
        } else {
            settingsWindow = EditorSettingsWindowViewModel(
                editorViewModel: editor,
                selectedSection: section,
                selectedPage: editor.requestedSettingsPage
            )
        }
        editor.requestedSettingsSection = nil
        editor.requestedSettingsPage = nil
        return true
    }

    isolated deinit {
        #if canImport(Darwin)
        scopedURL?.stopAccessingSecurityScopedResource()
        #endif
    }

    var document: EditorSceneDocument? { sceneDocumentID.flatMap { workbench.sceneDocument(id: $0) } ?? workbench.activeSceneDocument }
    private(set) var recentProjects: [EditorProjectReference] = []

    func openProject(at url: URL) throws {
        guard !isImmersed, document?.isDirty != true else { throw EditorVRWorkspaceError.closeCurrentScene }
        #if canImport(Darwin)
        let accessing = url.startAccessingSecurityScopedResource()
        #else
        let accessing = false
        #endif
        do {
            let metadata = try ProjectSystem.validateProjectLayout(at: url)
            let root = url.appendingPathComponent(metadata.paths.assets ?? "Assets", isDirectory: true)
            let candidates =
                (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? [])
                .filter { SceneDocumentFormat.isSceneFile($0) }.sorted { $0.path < $1.path }
            // Code-only projects can use Studio without an immersive authoring scene.
            if let first = candidates.first {
                _ = try EditorSceneModel.decode(from: String(contentsOf: first, encoding: .utf8))
            }
            let reference = try store.rememberProject(at: url, name: metadata.project.displayName ?? metadata.project.name)
            stopPlay()
            #if canImport(Darwin)
            scopedURL?.stopAccessingSecurityScopedResource()
            #endif
            scopedURL = accessing ? url : nil
            project = reference
            recentProjects = (try? store.loadProjects()) ?? []
            projectURL = url
            resourceRootURL = root
            scenes = candidates
            workbench.closeAllDocuments()
            sceneDocumentID = nil
            let items = EditorViewModel.buildProjectTreeItems(at: url, fileManager: .default)
            modelAssets = items.filter {
                !$0.isFolder && EditorModelResource.extensions.contains(URL(fileURLWithPath: $0.title).pathExtension.lowercased()) && $0.assetRoot != nil
            }.map { EditorViewModel.assetDocument(for: $0) }
            saveFailure = nil
            inspector.textureAssets = EditorViewModel.textureAssets(from: items)
            inspector.modelAssets = EditorViewModel.modelAssets(from: items)
            inspector.tileMapAssets = EditorViewModel.tileMapAssets(from: items)
            inspector.sceneAssets = EditorViewModel.sceneAssets(from: items)
            inspector.scriptableObjectCatalog =
                metadata.build.system.isAdaScript
                ? (try? EditorScriptableObjectCatalogLoader.load(project: metadata, at: url).descriptors) ?? [] : []
            if let first = candidates.first { try openScene(at: first) }
            connectStudio(reference)
            message = "Project opened"
        } catch {
            #if canImport(Darwin)
            if accessing { url.stopAccessingSecurityScopedResource() }
            #endif
            throw error
        }
    }

    /// Returns to the shared project launcher after the native host has left immersion.
    func closeProject() -> Bool {
        guard !isImmersed, !isOpening, workbench.saveAllDocuments() else {
            return false
        }
        stopPlay()
        viewport.disconnect()
        workbench.closeAllDocuments()
        studio = nil
        settingsWindow = nil
        project = nil
        projectURL = nil
        resourceRootURL = nil
        sceneDocumentID = nil
        scenes.removeAll()
        modelAssets.removeAll()
        #if canImport(Darwin)
        scopedURL?.stopAccessingSecurityScopedResource()
        #endif
        scopedURL = nil
        message = nil
        return true
    }

    func openRecent(_ reference: EditorProjectReference) {
        do { try openProject(at: store.resolveProjectURL(for: reference)) } catch { message = error.localizedDescription }
    }

    func openScene(at url: URL) throws {
        guard !isImmersed, document?.isDirty != true else { throw EditorVRWorkspaceError.closeCurrentScene }
        let content = try String(contentsOf: url, encoding: .utf8)
        let model = try EditorSceneModel.decode(from: content)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let relative = projectURL.map { String(url.path.dropFirst($0.path.count + 1)) } ?? url.lastPathComponent
        let scene = EditorSceneDocument(
            id: "scene:\(url.path)",
            title: url.lastPathComponent,
            relativePath: relative,
            absolutePath: url.path,
            content: content,
            lastSavedContent: content,
            isReadOnly: values.isSymbolicLink == true,
            sceneModel: model,
            errorMessage: nil,
            isDirty: false,
            statusMessage: "Opened",
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        sceneDocumentID = scene.id
        workbench.open(.scene(scene))
        synchronizeDocument()
    }

    func attachWorld(_ world: World) {
        guard let document else {
            return
        }
        let result = EditorSceneFileLoader.load(
            content: document.content,
            into: world,
            loadsScriptableObjects: false,
            sourceURL: document.absolutePath.map { URL(fileURLWithPath: $0) },
            resourceRootURL: resourceRootURL
        )
        viewport.attachImmersiveWorld(world, loadResult: result)
        synchronizeDocument()
        world.insertResource(SpatialInteractionSettings(mode: activeTool.spatialMode))
        boundsRefreshes = 0
        refreshGrabBounds(in: world)
        message = result.warnings.isEmpty ? "Immersive editor ready" : result.warnings.joined(separator: "\n")
    }

    func navigate(_ world: World, keys: Set<KeyCode> = [], wheel: Float = 0) -> Vector3 {
        let offset = navigation.update(in: world, keys: keys, wheel: isPointerOverPanel ? 0 : wheel, textEditing: isEditingText)
        isNavigating = navigation.isNavigating
        return offset
    }

    func input(_ world: World, camera: EditorSceneViewportModel.CameraState, size: Size) {
        gizmo.prepareInput(in: world, viewport: viewport, activeTool: activeTool, camera: camera, size: size)
    }

    func overlay(_ world: World, camera: EditorSceneViewportModel.CameraState, size: Size) -> [ImmersiveOverlayDrawing] {
        gizmo.drawings(in: world, viewport: viewport, activeTool: activeTool, camera: camera, size: size)
    }

    func frame(_ world: World) {
        palmWheel.update(in: world, tracking: world.getResource(SpatialTrackingFrame.self) ?? SpatialTrackingFrame()) {
            self.activatedPalmPanel = $0
        }
        if isPalmMenuVisible != palmWheel.isVisible { isPalmMenuVisible = palmWheel.isVisible }
        gizmo.consume(in: world, viewport: viewport, activeTool: activeTool)
        if boundsRefreshes < 20 {
            refreshGrabBounds(in: world)
            boundsRefreshes += 1
        }
        let selection = world.getResource(SpatialSelection.self)
        if let id = selection?.entityID.flatMap(viewport.authoredEditorID) {
            if viewport.selectedEditorID != id { viewport.selectSpatialEntity(id) }
            if selection?.isGrabbed == true, document?.isReadOnly == false {
                viewport.beginSpatialTransform(editorID: id)
                if let entity = viewport.runtimeEntity(for: id), let transform = entity.components[Transform.self] {
                    viewport.updateSpatialTransform(transform, editorID: id)
                }
            }
        }
        if activeTool == .select, selection?.entityID == nil, viewport.selectedEditorID != nil {
            viewport.selectSpatialEntity(nil)
        }
        let held = selection?.isGrabbed ?? false
        if isManipulating != held { isManipulating = held }
        if !isManipulating { viewport.endSpatialTransform() }
        gizmo.update(in: world, viewport: viewport, activeTool: activeTool)
    }

    func finishImmersion() {
        navigation.reset()
        isNavigating = false
        palmWheel.reset()
        isPalmMenuVisible = false
        gizmo.reset(in: nil)
        viewport.endSpatialTransform()
        viewport.disconnect()
        runtimeAccess = nil
        isImmersed = false
        isOpening = false
        isManipulating = false
    }

    func select(_ id: String) {
        guard !isManipulating else {
            return
        }
        if let runtimeAccess {
            runtimeAccess { world in
                self.viewport.selectSpatialEntity(id)
                world.insertResource(SpatialSelection(entityID: self.viewport.runtimeEntity(for: id)?.id))
            }
        } else {
            viewport.selectSpatialEntity(id)
        }
    }
    func save() {
        guard !isManipulating, let document else {
            return
        }
        let saved = workbench.saveDocument(.scene(document))
        saveFailure = saved ? nil : workbench.activeDocumentSaveFailureDescription ?? "Could not save this scene."
        message = saved ? "Scene saved" : saveFailure
    }
    func setTool(_ tool: EditorSceneViewportTool) {
        guard !isManipulating, document != nil, tool == .select || document?.isReadOnly == false else {
            return
        }
        edit {
            self.activeTool = tool
            self.viewport.setActiveTool(tool)
            self.viewport.setSpatialTool(tool.spatialMode)
        }
    }

    func undo() { edit { _ = self.workbench.performDocumentHistory(redo: false) } }
    func redo() { edit { _ = self.workbench.performDocumentHistory(redo: true) } }
    func addEntity(preset: EditorSceneEntityPreset = .empty) {
        edit { self.modifyDocument { model in _ = model.addEntity(preset: preset) } }
    }
    func addModel() { edit { self.modifyDocument { model in _ = model.addEntity(template: .model3D, parentID: nil) } } }
    func edit(_ action: @escaping @MainActor () -> Void) {
        guard !isManipulating else {
            return
        }
        if let runtimeAccess { runtimeAccess { _ in action() } } else { action() }
    }
    func modifyDocument(_ mutation: @escaping (inout EditorSceneModel) -> Void) {
        guard let document else {
            return
        }
        workbench.updateSceneModelDocument(id: document.id, status: "Edited", update: mutation)
    }

    private func synchronizeDocument() {
        guard let document else {
            return
        }
        let configure = { [weak self] in
            guard let self else {
                return
            }
            _ = self.viewport.configure(
                sceneContent: document.content,
                model: document.sceneModel,
                sourceURL: document.absolutePath.map { URL(fileURLWithPath: $0) },
                resourceRootURL: self.resourceRootURL,
                scriptableObjectCatalog: self.inspector.scriptableObjectCatalog,
                isHistoryChange: document.statusMessage == "Undo" || document.statusMessage == "Redo",
                replacesDocument: document.statusMessage == "Reloaded",
                onSelectionChanged: { [weak self] in self?.inspector.selectEntity($0) },
                onDocumentContentChanged: { [weak self] in self?.publishContent($0) },
                onTransformChanged: { [weak self] id, payload in self?.inspector.updateLiveTransform(editorID: id, payload: payload) }
            )
            self.boundsRefreshes = 0
        }
        if let runtimeAccess { runtimeAccess { _ in configure() } } else { configure() }
    }

    private func publishContent(_ content: String) {
        guard var document, document.content != content else {
            return
        }
        document.content = content
        document.sceneModel = EditorSceneFileLoader.model(from: content)
        document.loadSummary = EditorSceneFileLoader.summary(from: content)
        document.isDirty = content != document.lastSavedContent
        document.statusMessage = "Spatial edit"
        workbench.replaceSceneDocument(document)
    }

    private func refreshGrabBounds(in world: World) {
        guard let model = document?.sceneModel else {
            return
        }
        for authored in model.entities {
            guard let entity = viewport.runtimeEntity(for: authored.id) else { continue }
            if document?.isReadOnly == true || !authored.enabled {
                entity.components[SpatialGrabbable.self] = nil
                continue
            }
            guard entity.components[Camera.self] == nil, entity.components[DirectionalLightComponent.self] == nil else {
                entity.components[SpatialGrabbable.self] = nil
                continue
            }
            var boxes: [AABB] = []
            func collect(_ node: Entity, local: Transform3D) {
                if let mesh = node.components[Mesh3DComponent.self] { boxes.append(Self.transformedBounds(mesh.mesh.bounds, by: local)) }
                for child in node.children {
                    // Generated meshes belong to their authored model; authored children are separate targets.
                    guard viewport.authoredEditorID(for: child.id) == authored.id else { continue }
                    collect(child, local: local * (child.components[Transform.self]?.matrix ?? .identity))
                }
            }
            collect(entity, local: .identity)
            guard let first = boxes.first else {
                entity.components[SpatialGrabbable.self] = nil
                continue
            }
            var minimum = first.min
            var maximum = first.max
            for box in boxes.dropFirst() {
                for axis in 0..<3 {
                    minimum[axis] = min(minimum[axis], box.min[axis])
                    maximum[axis] = max(maximum[axis], box.max[axis])
                }
            }
            let bounds = AABB(min: minimum, max: maximum)
            entity.components[SpatialGrabbable.self] = SpatialGrabbable(halfExtents: bounds.halfExtents, center: bounds.center)
        }
    }

    private static func transformedBounds(_ box: AABB, by matrix: Transform3D) -> AABB {
        var minimum = Vector3(Float.infinity, Float.infinity, Float.infinity)
        var maximum = -minimum
        for x in [box.min.x, box.max.x] {
            for y in [box.min.y, box.max.y] {
                for z in [box.min.z, box.max.z] {
                    let point = (matrix * Vector4(x, y, z, 1)).xyz
                    for axis in 0..<3 {
                        minimum[axis] = min(minimum[axis], point[axis])
                        maximum[axis] = max(maximum[axis], point[axis])
                    }
                }
            }
        }
        return AABB(min: minimum, max: maximum)
    }

    private static func transformPayload(_ transform: Transform) -> EditorComponentPayload {
        [
            "position": .array([transform.position.x, transform.position.y, transform.position.z].map { .double(Double($0)) }),
            "rotation": .array([transform.rotation.x, transform.rotation.y, transform.rotation.z, transform.rotation.w].map { .double(Double($0)) }),
            "scale": .array([transform.scale.x, transform.scale.y, transform.scale.z].map { .double(Double($0)) }),
        ]
    }
}

enum EditorVRWorkspaceError: LocalizedError {
    case closeCurrentScene
    case noScenes
    var errorDescription: String? {
        switch self {
        case .closeCurrentScene: "Leave immersion and save the current scene before opening another project or scene."
        case .noScenes: "This project contains no editable .ascn scenes."
        }
    }
}
