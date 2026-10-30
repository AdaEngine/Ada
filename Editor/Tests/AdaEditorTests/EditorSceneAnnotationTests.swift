@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Desktop scene annotations", .serialized)
struct EditorSceneAnnotationTests {
    @Test("Notes keep stable numbers, editable text and the originating chat")
    func draftOwnership() throws {
        let state = EditorAgentSceneAnnotations()
        state.selectSession("first")
        state.toggleSelection()
        var prompt = "Change the scene"
        for id in ["tree", "house"] {
            state.select(context(id))
            state.draft?.note = "Improve \(id)"
            #expect(state.add(to: &prompt))
            #expect(state.isSelecting)
        }
        #expect(state.items.map(\.number) == [1, 2])
        let second = try #require(state.items.last)
        state.remove(try #require(state.items.first).id, from: &prompt)
        #expect(state.items.map(\.number) == [2])
        state.select(context("cloud"))
        #expect(state.draft?.number == 3)
        state.selectSession("second")
        #expect(state.items.isEmpty && state.draft == nil && !state.isSelecting)
        state.selectSession("first")
        #expect(state.items == [second])
        state.edit(second.id, prompt: prompt)
        state.draft?.note = "Paint the roof blue"
        #expect(state.add(to: &prompt))
        #expect(prompt.contains("Paint the roof blue"))
        #expect(!prompt.contains("Improve house"))
        #expect(state.items.first?.number == 2)
    }

    @Test("Manual message edits are preserved and old instructions are never replayed as context")
    func editedMessage() throws {
        let state = EditorAgentSceneAnnotations()
        state.selectSession("first")
        state.toggleSelection()
        state.select(context("tree"))
        state.draft?.note = "Old instruction"
        var prompt = ""
        #expect(state.add(to: &prompt))
        prompt = prompt.replacingOccurrences(of: "Old instruction", with: "New instruction")
        let item = try #require(state.items.first)
        state.edit(item.id, prompt: prompt)
        #expect(state.error != nil && state.draft == nil)
        let references = EditorAgentSceneAnnotation.referenceBlock(state.items)
        #expect(references.contains("tree") && references.contains("Assets/Main.ascn"))
        #expect(!references.contains("Old instruction"))
        state.remove(item.id, from: &prompt)
        #expect(state.items.isEmpty && prompt.contains("New instruction"))
    }

    @Test("Viewport clicks annotate in 2D and 3D without selecting or editing authored entities", arguments: [false, true])
    func viewportPicking(threeD: Bool) throws {
        setupRenderer()
        let world = World()
        world.spawn("SceneView_Camera") { Camera(); Transform() }
        let entity = world.spawn("Target") { Transform(); Sprite(size: Size(width: 20, height: 20)) }
        let viewport = EditorSceneViewportModel()
        viewport.attachSceneWorld(world, loadResult: .init(
            entityCount: 1, warnings: [], entitiesByEditorID: ["target": entity.id], editorIDsByEntityID: [entity.id: "target"]
        ))
        viewport.twoDZoom = 1
        viewport.threeDPosition = [0, 0, -5]
        viewport.threeDPitch = 0
        viewport.setViewportSize(Size(width: 100, height: 100))
        viewport.setDisplayMode(threeD ? .threeD : .twoD)
        viewport.perspectiveBlend = threeD ? 1 : 0
        viewport.sceneContent = "original scene"
        var picked: String?
        var picks = 0
        var selections = 0
        var edits = 0
        viewport.onAnnotateEntity = { picked = $0; picks += 1 }
        viewport.onSelectEntity = { _ in selections += 1 }
        viewport.onDocumentContentChanged = { _ in edits += 1 }
        viewport.setAnnotationMode(true)
        #expect(viewport.transformGizmo() == nil)
        for phase in [MouseEvent.Phase.began, .ended] {
            _ = viewport.handleInput(MouseEvent(window: RID(), button: .left, mousePosition: [50, 50], phase: phase, modifierKeys: [], time: 0))
        }
        #expect(picked == "target")
        for (phase, x) in [(MouseEvent.Phase.began, Float(50)), (.changed, 70), (.ended, 70)] {
            _ = viewport.handleInput(MouseEvent(window: RID(), button: .left, mousePosition: Point(x, 50), phase: phase, modifierKeys: [], time: 0))
        }
        #expect(picks == 1, "Dragging must not add a note")
        #expect(selections == 0 && edits == 0)
        #expect(viewport.sceneContent == "original scene")
        #expect(entity.components[Transform.self]?.position == .zero)
        viewport.setAnnotationMode(false)
        viewport.completeSelection(at: [50, 50])
        #expect(selections == 1)
    }

    @Test("Send carries object references and editable notes, then clears only the sent draft")
    func agentRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneAnnotations-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Annotations"), at: root)
        let service = FakeEditorAgentService()
        let agent = EditorAgentViewModel(project: .init(name: "Annotations", path: root.path), settings: EditorAgentSettingsStore(),
                                         service: service, notifications: EditorNotificationCenter())
        await agent.loadSessions()
        agent.sceneAnnotations.toggleSelection()
        agent.sceneAnnotations.select(context("tree"))
        agent.sceneAnnotations.draft?.note = "Make it taller"
        #expect(agent.sceneAnnotations.add(to: &agent.prompt))
        #expect(await service.recordedRequest() == nil)
        agent.prompt = agent.prompt.replacingOccurrences(of: "taller", with: "smaller")
        await agent.sendPromptAsync()
        let request = try #require(await service.recordedRequest())
        #expect(request.prompt.contains("smaller") && !request.prompt.contains("taller"))
        #expect(request.sceneAnnotations.first?.context.selectedEntityID == "tree")
        #expect(EditorAgentPromptContext.text(for: request).contains("Scene annotation references"))
        #expect(agent.sceneAnnotations.items.isEmpty && agent.prompt.isEmpty && !agent.sceneAnnotations.isSelecting)
        let user = try #require(agent.activeSession?.events.compactMap(\.message).first { $0.role == .user })
        let restored = try JSONDecoder().decode(EditorAgentMessage.self, from: JSONEncoder().encode(user))
        #expect(restored.sceneAnnotations?.first?.context.selectedEntityID == "tree")
        var followup = request
        followup.prompt = "Now move the house"
        followup.sceneAnnotations = []
        followup.session.events = [.init(kind: .message, message: restored),
                                   .init(kind: .message, message: .init(role: .user, segments: [.init(kind: .text, text: followup.prompt)]))]
        let hosted = EditorCloudAgentService(transportFactory: {
            { input, receive in
                let history = input["messages"].array.compactMap { $0["content"].string }.joined(separator: "\n")
                #expect(history.contains("tree") && history.contains("smaller"))
                #expect(!history.contains("taller"))
                try await receive(["type": "text", "text": "Done"])
                try await receive(["type": "complete"])
            }
        }, toolsFactory: { _ in [] })
        _ = try await hosted.send(followup, onEvent: { _ in }, onProjectFileChanged: { _ in })
    }

    private func context(_ id: String) -> EditorAgentSceneContext {
        .init(sceneTitle: "Main", sceneRelativePath: "Assets/Main.ascn", selectedEntityID: id, selectedEntityName: id,
              parentID: nil, componentNames: ["Transform"], entityYAML: "")
    }

    private func setupRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Annotations")))
        }
    }
}

@MainActor
extension EditorLocalizationTests {
    @Test("Annotation editor stays mounted and fits Russian and English labels")
    func annotationEditorLanguages() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AnnotationLocalization")))
        }
        let agent = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), service: FakeEditorAgentService(), notifications: EditorNotificationCenter())
        agent.sceneAnnotations.selectSession("localization")
        agent.sceneAnnotations.toggleSelection()
        agent.sceneAnnotations.select(.init(sceneTitle: "Scene", sceneRelativePath: "Assets/Main.ascn", selectedEntityID: "tree",
                                           selectedEntityName: "Большое дерево", parentID: nil, componentNames: [], entityYAML: ""))
        agent.sceneAnnotations.draft?.note = "Keep this note"
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        let container = UIContainerView(rootView: EditorSceneAnnotationEditor(agent: agent).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 310, height: 225)
        container.bounds.size = container.frame.size
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
            for id in ["Note", "Add", "Cancel"] {
                let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Annotations.\(id)"))
                #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= 310.5)
                #expect(node.absoluteFrame.minY >= 0 && node.absoluteFrame.maxY <= 225.5)
            }
            #expect(agent.sceneAnnotations.draft?.note == "Keep this note")
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Annotations.Add"))
        #expect(agent.prompt.contains("Keep this note"))
        #expect(agent.sceneAnnotations.items.count == 1 && !agent.isSending)
    }
}
