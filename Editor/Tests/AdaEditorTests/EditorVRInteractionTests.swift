@_spi(Internal) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@Suite("VR spatial controls", .serialized)
@MainActor
struct EditorVRInteractionTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test("Every right tool-strip button responds to touch through its hover and tooltip wrappers")
    func rightToolStripTouches() throws {
        let editor = EditorViewModel(project: nil)
        for item in editor.toolStrip.rightTools {
            editor.showRightPanel = false
            editor.requestedSettingsSection = nil
            let container = UIContainerView(rootView: EditorRightToolStrip(viewModel: editor, onSelectTool: { editor.activateRightTool($0) }).environment(\.theme, .adaEditor))
            container.frame = Rect(x: 0, y: 0, width: 44, height: 600)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ToolStrip.\(item.identifier)"))
            let point = Point(node.absoluteFrame.midX, node.absoluteFrame.midY)
            let id = RID()
            container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .began, time: 1, contactID: id)])
            container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .ended, time: 1.1, contactID: id)])
            if item.identifier == "projectSettings" { #expect(editor.requestedSettingsSection == .project) }
            else { #expect(editor.isRightToolPresented(item)) }
        }
    }

    @Test("Settings requests reuse a separate model without replacing Studio documents or drafts")
    func settingsWindowRouting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let editor = try #require(workspace.studio)
        let documentID = workspace.workbench.activeDocumentID
        editor.presentSettings(.project)
        #expect(workspace.prepareSettingsWindow())
        let settings = try #require(workspace.settingsWindow)
        #expect(settings.selectedSection == .project)
        #expect(settings.editorViewModel === editor)
        #expect(editor.requestedSettingsSection == nil)
        settings.codeFontSize = 23
        editor.presentSettings(.agent)
        #expect(workspace.prepareSettingsWindow())
        #expect(workspace.settingsWindow === settings)
        #expect(settings.selectedSection == .agent)
        #expect(settings.codeFontSize == 23)
        #expect(workspace.workbench.activeDocumentID == documentID)
        #expect(workspace.studio === editor)
        #expect(workspace.closeProject())
        #expect(workspace.settingsWindow == nil)
    }

    @Test("Native ornament hosting removes embedded tool strips and tabs but keeps the same source pane")
    func nativeOrnamentHosting() async throws {
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let editor = try #require(workspace.studio)
        let source = try #require(editor.projectSidebar.items.first { $0.title.hasSuffix(".ada") && !$0.isFolder })
        editor.openProjectItem(source)
        let selected = editor.workbench.activeDocumentID
        let documents = editor.workbench.openDocuments.map(\.id)
        let container = UIContainerView(rootView: EditorView(project: workspace.project, viewModel: editor, usesNativeOrnaments: true).environment(\.theme, .adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 2200, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ToolStrip.inspector")).isEmpty)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Tab.Select.\(selected)")).isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Workbench.Pane.primary")).isEmpty)
        #expect(editor.workbench.activeDocumentID == selected)
        #expect(editor.workbench.openDocuments.map(\.id) == documents)
        editor.workbench.filesBrowserPanes.insert(.primary)
        try await Task.sleep(for: .milliseconds(30))
        container.update(1 / 60)
        container.layoutIfNeeded()
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Files.Browser")).isEmpty)
        #expect(editor.workbench.activeDocumentID == selected)
    }

    @Test("Hierarchy touch selects the scene entity through the actual UI control")
    func hierarchyTouch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let box = try #require(workspace.document?.sceneModel?.entities.first { $0.name == "Box" })
        let container = UIContainerView(rootView: EditorVRHierarchyPanel(workspace: workspace).environment(\.theme, .adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 460)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy.Select.\(box.id)"))
        let point = Point(x: node.absoluteFrame.midX, y: node.absoluteFrame.midY)
        let id = RID()
        let began = TouchEvent(window: .empty, location: point, phase: .began, time: 1, contactID: id)
        container.onTouchesEvent([began])
        container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .ended, time: 1.1, contactID: id)])
        #expect(workspace.inspector.selectedEntity?.editorID == box.id)
        #expect(workspace.document?.sceneModel?.editor?.selectedEntity == box.id)
    }

    @Test("The real enum picker opens on touch and persists the selected visibility")
    func enumPickerTouch() throws {
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let box = try #require(workspace.document?.sceneModel?.entities.first { $0.name == "Box" })
        workspace.select(box.id)
        let field = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.visibility)?.fields.first)
        let binding = workspace.inspector.componentFieldBinding(typeName: EditorBuiltInComponentType.visibility, field: field)
        let container = UIContainerView(rootView: EditorEnumField(cases: ["visible", "hidden", "inherited"], selection: binding).environment(\.theme, .adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 40)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        defer { ContextMenuPresentationCenter.present = previous }
        ContextMenuPresentationCenter.present = { menu = $0 }
        let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        let point = Point(node.absoluteFrame.midX, node.absoluteFrame.midY)
        let id = RID()
        container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .began, time: 1, contactID: id)])
        container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: .ended, time: 1.1, contactID: id)])
        let items = try #require(menu?.items)
        #expect(items.first { $0.title == "visible" }?.isSelected == true)
        let selectHidden = try #require(items.first { $0.title == "hidden" }?.action)
        selectHidden()
        #expect(binding.wrappedValue == "hidden")
        workspace.save()
        let path = try #require(workspace.document?.absolutePath)
        let saved = try EditorSceneModel.decode(from: String(contentsOfFile: path, encoding: .utf8))
        #expect(saved.entities.first { $0.id == box.id }?.components[EditorBuiltInComponentType.visibility]?["value"] == .string("hidden"))
    }

    @Test("Visible X gizmo moves only X and commits one undo step on release")
    func gizmoAxis() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let box = try #require(workspace.document?.sceneModel?.entities.first { $0.name == "Box" })
        let world = World()
        workspace.attachWorld(world)
        workspace.select(box.id)
        world.insertResource(SpatialInput())
        world.insertResource(SpatialSelection())
        world.addSystem(SpatialInteractionSystem.self, on: .update)
        workspace.frame(world)
        #expect(world.getEntities().filter { $0.name.hasPrefix("VR Selection Edge") }.count == 12)
        let size = Size(width: 800, height: 600)
        var projection = PerspectiveProjection(near: 0.1, far: 100, fieldOfView: .degrees(62), aspectRation: size.width / size.height)
        projection.updateView(width: size.width, height: size.height)
        let camera = EditorSceneViewportModel.CameraState(projection: .perspective(projection), transform: Transform(position: [0, 1.6, -1.5]), renderGraphLabel: .main3D)
        let gizmo = try #require(
            EditorVRGizmoController().definition(
                in: world, viewport: workspace.viewport, tool: .translate, camera: camera, size: size
            )
        )
        let screen = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let start = try #require(EditorTransformGizmo.unproject(screen, depth: gizmo.depth, inverse: gizmo.viewProjection.inverse, size: size))
        let drawings = workspace.overlay(world, camera: camera, size: size)
        #expect(!drawings.isEmpty)
        #expect(world.getEntities().filter { $0.name.hasPrefix("VR Gizmo") }.allSatisfy { $0.components[Mesh3DComponent.self] == nil })
        let owner = try #require(workspace.viewport.runtimeEntity(for: box.id))
        let before = try #require(owner.components[Transform.self])
        let baseline = workspace.document?.content
        for point in [start, start + Vector3(0.3, 0.2, 0.1)] {
            world.insertResource(SpatialInput(grips: [SpatialGrip(interactor: .leftHand, pose: Transform3D(translation: point))]))
            workspace.input(world, camera: camera, size: size)
            await world.runScheduler(.update)
            workspace.frame(world)
        }
        let moved = try #require(owner.components[Transform.self])
        #expect(abs(moved.position.x - before.position.x - 0.3) < 0.005)
        #expect(moved.position.y == before.position.y)
        #expect(moved.position.z == before.position.z)
        #expect(workspace.document?.content == baseline)
        world.insertResource(SpatialInput())
        workspace.input(world, camera: camera, size: size)
        await world.runScheduler(.update)
        workspace.frame(world)
        #expect(workspace.canUndo)
        let feedbackIDs = Set(world.getEntities().filter { $0.name.hasPrefix("VR Selection Edge") || $0.name.hasPrefix("VR Gizmo") }.map(\.id))
        workspace.undo()
        workspace.frame(world)
        #expect(Set(world.getEntities().filter { $0.name.hasPrefix("VR Selection Edge") || $0.name.hasPrefix("VR Gizmo") }.map(\.id)) == feedbackIDs)
    }

    @Test("The shared Studio edits and saves a real source file without losing the immersive scene")
    func sharedStudioDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json")))
        try workspace.createStarter(at: directory)
        let scene = try #require(workspace.document)
        let studio = try #require(workspace.studio)
        let item = try #require(studio.projectSidebar.items.first { $0.title.hasSuffix(".ada") && !$0.isFolder })
        studio.openProjectItem(item)
        let source = try #require(studio.workbench.textDocument(id: studio.workbench.activeDocumentID))
        let updated = source.content + "\n// Edited in VR Studio\n"
        studio.workbench.textDocumentBinding(documentID: source.id).wrappedValue = updated
        #expect(studio.workbench.saveActiveDocument())
        let path = try #require(studio.workbench.textDocument(id: studio.workbench.activeDocumentID)?.absolutePath)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == updated)
        #expect(workspace.document?.id == scene.id)
        #expect(workspace.document?.sceneModel?.entities == scene.sceneModel?.entities)
    }

    @Test("Project panel routes ordinary Enter to Full and its separate Mixed button to passthrough")
    func projectImmersionButtons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = EditorVRWorkspace(store: EditorProjectStore(storageURL: root.appendingPathComponent("recents.json")))
        try workspace.createStarter(at: root)
        var state = EditorVRImmersionState()
        let container = UIContainerView(rootView: EditorVRProjectPanel(
            workspace: workspace, openProject: {}, createProject: {},
            enter: { state.request(allowed: true) }, leave: {},
            enterMixed: { state.request(.mixed, allowed: true) }
        ).environment(\.theme, .adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 420, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.VR.Project.EnterMixed"))
        #expect(state.mode == .mixed)
        state.finishEntryAttempt()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.VR.Project.Enter"))
        #expect(state.mode == .full)
    }

    @Test("Palm sector selection opens a panel once and restores scene selection")
    func palmSelection() throws {
        let world = World()
        let selected = world.spawn("Selected scene entity") { Transform() }
        world.insertResource(SpatialSelection(entityID: selected.id))
        let wheel = EditorVRPalmWheel()
        var opened: [EditorVRPanel] = []
        let tracking = SpatialTrackingFrame(hands: [
            SpatialHandPose(interactor: .leftHand, pose: Transform3D(translation: [0, 0, 0.5]), palmNormal: [0, 0, -1], isOpen: true)
        ])
        wheel.update(in: world, tracking: tracking) { opened.append($0) }
        #expect(wheel.isVisible)
        let code = try #require(world.getEntities().first { $0.name == "Palm Code" })
        world.insertResource(SpatialSelection(entityID: code.id))
        wheel.update(in: world, tracking: tracking) { opened.append($0) }
        #expect(opened == [.code])
        #expect(!wheel.isVisible)
        #expect(world.getResource(SpatialSelection.self)?.entityID == selected.id)
        wheel.update(in: world, tracking: tracking) { opened.append($0) }
        #expect(opened == [.code])
        #expect(!wheel.isVisible)
        // Lowering the hand releases suppression before the palm is raised again.
        wheel.update(in: world, tracking: SpatialTrackingFrame()) { opened.append($0) }
        wheel.update(in: world, tracking: tracking) { opened.append($0) }
        #expect(wheel.isVisible)
        let close = try #require(world.getEntities().first { $0.name == "Palm Close" })
        world.insertResource(SpatialSelection(entityID: close.id))
        wheel.update(in: world, tracking: tracking) { opened.append($0) }
        #expect(!wheel.isVisible)
        #expect(opened == [.code])
        #expect(world.getResource(SpatialSelection.self)?.entityID == selected.id)
        wheel.reset()
        let nextWorld = World()
        wheel.update(in: nextWorld, tracking: tracking) { opened.append($0) }
        #expect(wheel.isVisible)
        #expect(nextWorld.getEntities().filter { $0.name.hasPrefix("Palm ") && $0.components[SpatialGrabbable.self] != nil }.count == 7)
    }

    @Test("The shared project chooser opens Studio before explicit immersion and can return to projects")
    func sharedProjectChooser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json"))
        let reference = try store.createProject(named: "SharedLaunch", at: directory, template: .adaScript)
        let chooser = ProjectOpeningViewModel(store: store)
        let workspace = EditorVRWorkspace(store: store)
        #expect(workspace.project == nil && workspace.studio == nil)
        chooser.openRecentProject(reference)
        let request = try #require(chooser.consumeProjectToOpenInEditor())
        try workspace.openProject(at: store.resolveProjectURL(for: request))
        let editor = try #require(workspace.studio)
        #expect(editor.workbench === workspace.workbench)
        #expect(!workspace.isImmersed && !workspace.isOpening)
        #expect(workspace.presentedPanels.isEmpty)
        let item = try #require(editor.projectSidebar.items.first { $0.title.hasSuffix(".ada") && !$0.isFolder })
        editor.openProjectItem(item)
        let document = try #require(editor.workbench.textDocument(id: editor.workbench.activeDocumentID))
        let content = document.content + "\n// Shared Studio launch flow\n"
        editor.workbench.textDocumentBinding(documentID: document.id).wrappedValue = content
        #expect(workspace.closeProject())
        #expect(workspace.project == nil && workspace.studio == nil && workspace.document == nil)
        #expect(try String(contentsOfFile: try #require(document.absolutePath), encoding: .utf8) == content)
        chooser.reloadRecentProjects()
        #expect(chooser.recentProjects.contains { $0.path == reference.path })
    }

    @Test("Studio opens a valid project without scenes; immersion waits for an active scene")
    func studioWithoutScenes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorProjectStore(storageURL: directory.appendingPathComponent("recent.json"))
        let reference = try store.createProject(named: "CodeOnly", at: directory, template: .adaScript)
        let root = try store.resolveProjectURL(for: reference)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let scenes = files.allObjects.compactMap { $0 as? URL }.filter { SceneDocumentFormat.isSceneFile($0) }
        for file in scenes { try FileManager.default.removeItem(at: file) }
        let workspace = EditorVRWorkspace(store: store)
        try workspace.openProject(at: root)
        #expect(workspace.studio != nil && workspace.document == nil)
        #expect(workspace.scenes.isEmpty && !workspace.isImmersed)
    }

    @Test("Palm occlusion state follows real tracking and resets when immersion ends")
    func palmOcclusionState() {
        let workspace = EditorVRWorkspace()
        let world = World()
        let tracking = SpatialTrackingFrame(hands: [
            SpatialHandPose(interactor: .leftHand, pose: Transform3D(translation: [0, 0, 0.5]), palmNormal: [0, 0, -1], isOpen: true)
        ])
        world.insertResource(tracking)
        workspace.frame(world)
        #expect(workspace.isPalmMenuVisible)
        let sector = world.getEntities().first { $0.name == "Palm Code" }
        #expect(abs((sector?.components[Transform.self]?.position.z ?? 0) - 0.44) < 0.0001)
        world.removeResource(SpatialTrackingFrame.self)
        workspace.frame(world)
        #expect(!workspace.isPalmMenuVisible)
        world.insertResource(tracking)
        workspace.frame(world)
        #expect(workspace.isPalmMenuVisible)
        workspace.finishImmersion()
        #expect(!workspace.isPalmMenuVisible)
    }

    @Test("Palm activation requires an open hand facing the head in front of the viewer")
    func palmGesture() {
        let head = Transform3D.identity
        let hand = SpatialHandPose(interactor: .leftHand, pose: Transform3D(translation: [0, -0.1, 0.45]), palmNormal: [0, 0, -1], isOpen: true)
        #expect(EditorVRPalmWheel.shouldPresent(hand: hand, head: head))
        var closed = hand
        closed.isOpen = false
        #expect(!EditorVRPalmWheel.shouldPresent(hand: closed, head: head))
        var behind = hand
        behind.pose.origin.z = -0.45
        #expect(!EditorVRPalmWheel.shouldPresent(hand: behind, head: head))
    }
}
