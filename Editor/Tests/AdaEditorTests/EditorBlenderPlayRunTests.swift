#if os(Windows)
import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Blender model Play evidence", .serialized)
struct EditorBlenderPlayRunTests {
    @Test func exactRunAndModelReferenceAreRequired() throws {
        let run = EditorTrackedScenePlay(id: UUID(), sceneDocumentID: "scene", entityID: "job-entity", sceneRevision: "revision")
        let otherRun = EditorTrackedScenePlay(id: UUID(), sceneDocumentID: "scene", entityID: "job-entity", sceneRevision: "revision")
        let world = World(name: "Blender Play run verification")
        let entity = world.spawn("Traffic Cone") {}
        let root = world.spawn("Imported model root") {}
        entity.addChild(root)
        let modelPath = "C:/Projects/Game/Assets/Models/Cone.glb"
        let model = Model3DSource(source: modelPath)
        entity.components[Model3DSource.self] = model
        world.flush()
        run.install(in: world, result: .init(entityCount: 1, warnings: [], entitiesByEditorID: [run.entityID: entity.id], editorIDsByEntityID: [entity.id: run.entityID]))
        #expect(try !run.isLoaded(modelPath: modelPath, in: world))
        entity.components[Model3DSourceState.self] = Model3DSourceState(reference: model, rootEntityID: root.id)
        #expect(try run.isLoaded(modelPath: modelPath, in: world))
        #expect(try !otherRun.isLoaded(modelPath: modelPath, in: world))
        #expect(try !run.isLoaded(modelPath: "C:/Projects/OtherGame/Assets/Models/Cone.glb", in: world))
        entity.components[Model3DSourceState.self] = Model3DSourceState(reference: model, rootEntityID: root.id, error: "Replacement failed")
        #expect(throws: (any Error).self) { try run.isLoaded(modelPath: modelPath, in: world) }
    }

    @Test func cancelledAndSupersededRunsFailBeforeCapture() async throws {
        let run = EditorTrackedScenePlay(id: UUID(), sceneDocumentID: "scene", entityID: "job-entity", sceneRevision: "revision")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("Unused Blender Play \(UUID().uuidString)")
        let modelPath = project.appendingPathComponent("Assets/Models/Cone.glb").path
        await #expect(throws: (any Error).self) {
            _ = try await EditorGameFrameCapture.captureTrackedModel(run, modelPath: modelPath, projectURL: project, isCurrent: { false })
        }
        let capture = Task { try await EditorGameFrameCapture.captureTrackedModel(run, modelPath: modelPath, projectURL: project, isCurrent: { true }) }
        capture.cancel()
        await #expect(throws: CancellationError.self) { _ = try await capture.value }
        #expect(!FileManager.default.fileExists(atPath: project.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_STUDIO_BLENDER_PLAY_QA_GLB"] != nil))
    func capturesImportedConeFromNativePlayWorld() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["ADA_STUDIO_BLENDER_PLAY_QA_GLB"]))
        let temporaryProject = FileManager.default.temporaryDirectory.appendingPathComponent("Blender Play \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryProject, withIntermediateDirectories: false)
        let project = temporaryProject.resolvingSymlinksInPath().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: project) }
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .saga
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Blender GPU Play")))
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let starter = try #require(EditorAgentKnowledge.examples.first { $0.id == "basic-3d-scene" })
        for (path, contents) in starter.files {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let job = UUID().uuidString.lowercased()
        let staging = project.appendingPathComponent("Downloads/Blender/\(job)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bytes = try Data(contentsOf: source)
        try bytes.write(to: staging.appendingPathComponent("Model.glb"), options: .withoutOverwriting)
        try EditorBlenderSceneJob.recordExport(bytes, project: project, id: job, name: "Traffic Cone")

        let scene = SceneDocumentFormat.defaultScenePath
        let contents = try #require(starter.files[scene])
        let editor = EditorViewModel(project: EditorProjectReference(name: "Basic 3D", path: project.path))
        editor.workbench.open(.scene(.init(
            id: scene,
            title: "Main.ascn",
            relativePath: scene,
            absolutePath: project.appendingPathComponent(scene).path,
            content: contents,
            lastSavedContent: contents,
            sceneModel: try EditorSceneModel.decode(from: contents),
            isDirty: false,
            loadSummary: EditorSceneFileLoader.summary(from: contents)
        )))
        EditorAgentMCPTools.shared.activate(editor)
        defer { EditorAgentMCPTools.shared.deactivate(editor) }
        _ = try await EditorBlenderSceneAction.importModel(job: job, scene: scene, destination: "Assets/Models").run(project: project)
        _ = try await EditorBlenderSceneAction.place(
            job: job, scene: scene, revision: EditorAgentSceneToolService.revision(for: contents), position: [1, 0, 0]
        ).run(project: project)
        editor.interface.mode = .agent
        #expect(!editor.interface.showsArtifact)
        let verification = Task { try await EditorBlenderSceneAction.verify(job: job, scene: scene).run(project: project) }
        defer { verification.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while editor.trackedScenePlay == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let run = try #require(editor.trackedScenePlay)
        #expect(editor.interface.showsArtifact)
        let saved = try #require(editor.workbench.activeSceneDocument)
        let viewport = EditorSceneViewportView(
            document: saved,
            resourceRootURL: project.appendingPathComponent("Assets"),
            inspectorViewModel: editor.inspectorSidebar,
            playModeState: editor.playModeState,
            trackedScenePlay: run,
            playRuntime: editor.scenePlayRuntime,
            onEntitySelected: nil,
            onPlay: nil,
            onStop: nil,
            onDocumentChanged: { _ in }
        )
        let runtime = OffscreenSceneRuntime(label: EditorGameFrameCapture.gameLabel, size: SizeInt(width: 720, height: 480), useSceneCameras: true) {
            viewport.configurePlayWorld(&$0)
        }
        defer { runtime.stop(); editor.stopPlayMode() }
        try await runtime.start()
        let capture = try await verification.value
        #expect(capture["stage"].string == "captured")
        #expect(capture["reason"].string == nil)
        #expect(capture["runtimeModelLoaded"].bool == true)
        #expect(capture["runID"].string == run.id.uuidString)
        #expect(capture["activeCameras"].array.contains("Camera"))
        let url = project.appendingPathComponent(try #require(capture["capturePath"].string))
        if let output = environment["ADA_STUDIO_BLENDER_PLAY_QA_PNG"] {
            try Data(contentsOf: url).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let image = try Image(contentsOf: url)
        let hasOrangePixels = stride(from: 0, to: image.height, by: 4).contains { y in
            stride(from: 0, to: image.width, by: 4).contains { x in
                let color = image.getPixel(x: x, y: y)
                return color.red > 0.3 && color.red > color.green * 1.5 && color.green > color.blue * 1.1
            }
        }
        #expect(hasOrangePixels)
    }
}
#endif
