@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import MCP
import Testing

@testable import AdaEditor

@Suite("Animation authoring documents", .serialized)
@MainActor
struct EditorAnimationAuthoringTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Animation authoring tests")))
        }
    }

    @Test func draftsAreNotAutosavedOrSavedBySwitchingAndClosingTabs() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let document = try service.create("Assets/Animations/Draft.animlib", library: library())
        fixture.editor.workbench.selectDocument(id: "asset:\(document.relativePath)")
        try document.apply([.init(kind: .configureClip, clipID: "idle", name: "Changed")], expectedRevision: document.revision)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: document.url.path))
        #expect(document.isDirty)
        fixture.editor.workbench.selectDocument(id: "scene:Assets/Main.ascn")
        #expect(!FileManager.default.fileExists(atPath: document.url.path))
        fixture.editor.workbench.closeDocument(id: "asset:\(document.relativePath)")
        #expect(!FileManager.default.fileExists(atPath: document.url.path))
        #expect(fixture.editor.workbench.openDocuments.contains { $0.id == "asset:\(document.relativePath)" })
        try document.save(expectedRevision: document.revision)
        fixture.editor.workbench.closeDocument(id: "asset:\(document.relativePath)")
        #expect(!fixture.editor.workbench.openDocuments.contains { $0.id == "asset:\(document.relativePath)" })
        #expect(try service.open(document.relativePath).library.clips.first?.name == "Changed")
    }

    @Test func sharedRequestsUseRevisionedUndoAndExplicitDiskRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let document = try service.create("Assets/Test.animlib", library: library())
        try document.save(expectedRevision: document.revision)
        let revision = document.revision
        let request = AnimationAuthoringRequest(action: .apply, path: document.relativePath, expectedRevision: revision,
            operations: [.init(id: "rename", kind: .configureClip, clipID: "idle", name: "From API")])
        let response = try await service.execute(request, workbench: fixture.editor.workbench)
        #expect(response["revision"] as? String == document.revision)
        #expect(document.library.clips.first?.name == "From API")
        await #expect(throws: AnimationAuthoringError.self) { _ = try await service.execute(request, workbench: fixture.editor.workbench) }
        try document.undo(expectedRevision: document.revision)
        #expect(document.library.clips.first?.name == "Idle")
        try document.redo(expectedRevision: document.revision)
        #expect(document.library.clips.first?.name == "From API")
        var external = library(); external.clips[0].name = "External"
        try external.encodedData().write(to: document.url)
        #expect(throws: AnimationAuthoringError.self) { try document.save(expectedRevision: document.revision) }
        #expect(throws: AnimationAuthoringError.self) { try service.reload(document, expectedRevision: document.revision) }
        try service.reload(document, expectedRevision: document.revision, discardChanges: true)
        #expect(document.library == external)
        #expect(!document.isDirty && !document.canUndo)
        let old = document.revision
        _ = try await service.execute(.init(action: .discard, path: document.relativePath, expectedRevision: old, discardChanges: true), workbench: fixture.editor.workbench)
        #expect(service.documents.isEmpty)
        #expect(document.isDiscarded)
        #expect(try service.open(document.relativePath) !== document)
    }

    @Test func sceneReferencesAndOpenDocumentsRejectChangedResourceLocations() throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let scene = fixture.root.appendingPathComponent("Assets/Scenes/Main.ascn")
        // Payload resolution checks existence/extension here; native decoding is exercised by the extraction test.
        try Data().write(to: fixture.root.appendingPathComponent("Assets/Robot.glb"))
        #expect(EditorSceneFileLoader.resolveTileMapReference("../../Outside.animlib", relativeTo: scene,
            resourceRootURL: service.assetsURL, fileExtension: "animlib") == nil)
        #expect(throws: (any Error).self) {
            _ = try EditorSceneFileLoader.resolvedComponentPayload(typeName: EditorBuiltInComponentType.model3DSource,
                payload: ["source": .string("@res://Robot.glb"), "animationLibraries": .array([.string("../../Outside.animlib")])],
                sourceURL: scene, resourceRootURL: service.assetsURL)
        }
        let document = try service.create("Assets/Animations/Location.animlib", library: library())
        let originalDirectory = document.url.deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Removing an empty, exact fixture directory is safe; no recursive path calculation is used.
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: originalDirectory)
        try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: outside)
        #expect(throws: AnimationAuthoringError.self) { try document.save(expectedRevision: document.revision) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("Location.animlib").path))
        try service.discard(document, expectedRevision: document.revision, discardChanges: true)
        #expect(service.documents.isEmpty)
    }

    @Test func projectDeletionEvictsCachedDraftAndAllowsRecreation() throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let document = try service.create("Assets/Deleted.animlib", library: library())
        try document.save(expectedRevision: document.revision)
        try FileManager.default.removeItem(at: document.url)
        fixture.editor.workbench.discardDocuments(atOrBelow: document.relativePath)
        #expect(service.documents.isEmpty)
        #expect(document.isDiscarded)
        let recreated = try service.create(document.relativePath, library: library())
        #expect(recreated !== document)
    }

    @Test func nativeExtractionBindingGraphAndRuntimeReopenPreserveSourceAndRejectDuplicates() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
        let modelURL = fixture.root.appendingPathComponent("Assets/Robot.glb")
        let original = try Data(contentsOf: source)
        try original.write(to: modelURL)
        let document = try await service.extract(path: "Assets/Robot.animlib", modelPath: "Assets/Robot.glb", clipName: "Walk", name: "Editable Walk")
        let clip = try #require(document.library.clips.first)
        let initial = try document.library.sample(clipID: clip.id, at: 0)
        let animated = try document.library.sample(clipID: clip.id, at: 0.25)
        #expect(initial.localTransforms != animated.localTransforms)
        #expect(try Data(contentsOf: modelURL) == original)
        try document.save(expectedRevision: document.revision)
        let sceneID = "scene:Assets/Main.ascn"
        fixture.editor.workbench.updateSceneModelDocument(id: sceneID, status: "Test model") { scene in
            scene.entities.append(.init(id: "robot", name: "Robot", enabled: true, parent: nil, components: [
                EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform),
                EditorBuiltInComponentType.model3DSource: ["source": .string("@res://Robot.glb"), "animation": .string("Walk"), "autoplay": .bool(true), "repeats": .bool(true)]
            ]))
        }
        let before = try #require(fixture.editor.workbench.sceneDocument(id: sceneID))
        try await fixture.editor.workbench.bindAnimationLibrary(document, sceneID: sceneID, entityID: "robot",
            expectedSceneRevision: EditorAgentSceneToolService.revision(for: before.content), expectedResourceRevision: document.revision, clipID: clip.id)
        let bound = try #require(fixture.editor.workbench.sceneDocument(id: sceneID))
        let reference = try #require(bound.sceneModel?.entities.first { $0.id == "robot" }?.components[EditorBuiltInComponentType.model3DSource])
        #expect(reference["animation"] == .string(document.library.runtimeName(for: clip.id)))
        let duplicate = try service.create("Assets/Duplicate.animlib", library: document.library)
        try duplicate.save(expectedRevision: duplicate.revision)
        await #expect(throws: (any Error).self) {
            try await fixture.editor.workbench.bindAnimationLibrary(duplicate, sceneID: sceneID, entityID: "robot",
                expectedSceneRevision: EditorAgentSceneToolService.revision(for: bound.content), expectedResourceRevision: duplicate.revision, clipID: clip.id)
        }
        #expect(fixture.editor.workbench.sceneDocument(id: sceneID)?.content == bound.content)
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let model = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: modelURL.path).asset)
        var modelSource = try #require(try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: reference) as? Model3DSource)
        let qualified = document.library.runtimeName(for: clip.id)
        modelSource.animationGraph = .init(root: "walk", nodes: [.init(id: "walk", kind: .clip, clip: qualified)])
        let world = World()
        let owner = world.spawn("Owner") { Transform() }
        let root = try modelSource.instantiate(model, libraries: [document.library], in: world, under: owner)
        #expect(root.components[ModelAnimation3DComponent.self]?.player.clips.contains { $0.name == qualified } == true)
        let childCount = owner.children.count
        modelSource.animationLibraries.append("@res://Duplicate.animlib")
        #expect(throws: (any Error).self) { _ = try modelSource.instantiate(model, libraries: [document.library, duplicate.library], in: world, under: owner) }
        #expect(owner.children.count == childCount)
        #expect(world.getEntityByID(root.id) != nil)
        try service.close(document.relativePath)
        #expect(try service.open(document.relativePath).library == document.library)
        #expect(try Data(contentsOf: modelURL) == original)
    }

    @Test func documentedToolPanelUsesTheSameDraftAndRevocationCancelsQueuedJobs() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
        try FileManager.default.copyItem(at: source, to: fixture.root.appendingPathComponent("Assets/Robot.glb"))
        let document = try await service.extract(path: "Assets/Test.animlib", modelPath: "Assets/Robot.glb", clipName: "Walk", name: "Editable Walk")
        try document.save(expectedRevision: document.revision)
        let original = document.library
        let sceneID = "scene:Assets/Main.ascn"
        fixture.editor.workbench.updateSceneModelDocument(id: sceneID, status: "Test model") { scene in
            scene.entities.append(.init(id: "robot", name: "Robot", enabled: true, parent: nil, components: [
                EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform),
                EditorBuiltInComponentType.model3DSource: ["source": .string("@res://Robot.glb"), "animation": .string("Walk"), "autoplay": .bool(true), "repeats": .bool(true)]
            ]))
        }
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Examples/StudioTools/AnimationHelper")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Tools"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example, to: fixture.root.appendingPathComponent("Tools/AnimationHelper"))
        let host = EditorStudioToolHost(defaults: try #require(UserDefaults(suiteName: "AnimationTools-\(UUID())")))
        defer { host.close() }
        host.open(projectURL: fixture.root, editor: fixture.editor)
        host.enable("studio.animation-helper")
        host.approve(try #require(host.permissionRequest).id)
        #expect(host.error == nil)
        let panel = try #require(host.selectedPanel)
        panel.session.context.set("path", to: .string(document.relativePath))
        func performAndPoll(_ action: String) async throws {
            panel.session.context.perform(action)
            for _ in 0..<20 { await Task.yield() }
            for _ in 0..<200 {
                panel.session.context.perform("poll")
                for _ in 0..<20 { await Task.yield() }
                if panel.runtime.values["job"] == .string("") || panel.error != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(panel.error == nil)
            #expect(panel.runtime.values["job"] == .string(""))
        }
        try await performAndPoll("inspect")
        #expect(panel.runtime.values["revision"] == .string(document.revision))
        #expect(panel.runtime.values["clipID"] == .string(original.clips[0].id))
        try await performAndPoll("inspectTracks")
        try await performAndPoll("inspectKeys")
        guard case let .string(trackID) = panel.runtime.values["trackID"],
            let track = original.clips[0].tracks.first(where: { $0.id == trackID }), let first = track.keys.first else {
            Issue.record("The real Tool must inspect a compatible rotation track and key.")
            return
        }
        #expect(track.channel == .rotation)
        #expect(panel.runtime.values["keyID"] == .string(first.id))
        try await performAndPoll("rotateBone")
        var key = first
        key.value = [0, 0, 0.70710677, 0.70710677]
        let edit = AnimationEdit(id: "rotate-bone", kind: .putKey, clipID: original.clips[0].id, trackID: track.id, key: key, replaceExisting: true)
        let ui = try service.create("Assets/UI.animlib", library: original)
        try ui.apply([edit], expectedRevision: ui.revision)
        let agent = try service.create("Assets/Agent.animlib", library: original)
        let request = AnimationAuthoringRequest(action: .apply, path: agent.relativePath, expectedRevision: agent.revision, operations: [edit])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        _ = try await EditorAgentAnimationTools.execute(name: "editor.animation.apply", arguments: ["requestJSON": .string(json)], viewModel: fixture.editor)
        #expect(ui.library == agent.library)
        #expect(document.library == agent.library)
        await #expect(throws: (any Error).self) {
            _ = try await EditorAgentAnimationTools.execute(name: "editor.animation.inspect", arguments: ["requestJSON": .string(json)], viewModel: fixture.editor)
        }
        #expect(document.isDirty)
        try await performAndPoll("sample")
        guard case let .double(sampledZ) = panel.runtime.values["sampledRotationZ"] else {
            Issue.record("The Tool must read a sampled bone rotation from a nested pose/list response.")
            return
        }
        #expect(abs(sampledZ - Double(key.value[2])) < 0.00001)
        try await performAndPoll("save")
        #expect(!document.isDirty)
        #expect(try AnimationLibrary.decode(Data(contentsOf: document.url)) == document.library)
        try await performAndPoll("bind")
        let bound = try #require(fixture.editor.workbench.sceneDocument(id: sceneID)?.sceneModel?.entities.first { $0.id == "robot" })
        #expect(bound.components[EditorBuiltInComponentType.model3DSource]?["animation"] == .string(document.library.runtimeName(for: original.clips[0].id)))
        try await performAndPoll("oneShot")
        #expect(document.library.clips.first?.repeats == false)
        #expect(document.isDirty)
        panel.session.context.perform("save")
        host.disable("studio.animation-helper")
        for _ in 0..<40 { await Task.yield() }
        #expect(host.panels.isEmpty)
        #expect(document.isDirty)
        #expect(try AnimationLibrary.decode(Data(contentsOf: document.url)).clips.first?.repeats == true)
    }

    @Test func scriptRequestExpansionIsBoundedBeforeJSONEncoding() throws {
        let source = AdaScriptSource(path: "Amplify.ada", source: """
            @tool(id: "test.expansion", api: 2, platforms: ["macos", "windows"], permissions: ["editor.animations.read"])
            class Amplify {
                func activate(editor) { editor.addPanel(id: "main", title: "Tests", location: "right", ui: "Panel.ui"); }
                func amplify(editor) {
                    var value = ["leaf": "value"];
                    var i = 0;
                    while (i < 14) { value = ["a": value, "b": value]; i += 1; }
                    editor.animations.submit(["action": "inspect", "path": "Assets/Test.animlib", "extra": value]);
                }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        do {
            _ = try runtime.perform("amplify", inputs: [:], scene: nil)
            Issue.record("Expanded request graphs must fail before JSON encoding.")
        } catch {
            #expect(String(describing: error).contains("conversion budget"))
        }
        #expect(runtime.takeAnimationJobs().isEmpty)
    }

    @Test func authoringImportBoundsAccessorAllocationsAndRepeatedDecoding() throws {
        let root = FileManager.default.temporaryDirectory
        // The oversized accessor is deliberately unused: Red never attempts the giant allocation.
        let unused = Data(#"{"asset":{"version":"2.0"},"accessors":[{"componentType":5126,"count":1000000000,"type":"SCALAR"}]}"#.utf8)
        #expect(throws: NativeGLTFLoader.GLTFError.self) { _ = try NativeGLTFLoader(resourceRoot: root).load(data: unused, baseURL: root) }
        // A small zero-based accessor is legal without a buffer. Repeated references still consume decoded work.
        let primitive: [String: Any] = ["attributes": ["POSITION": 0]]
        let object: [String: Any] = ["asset": ["version": "2.0"],
            "accessors": [["componentType": 5126, "count": 16, "type": "VEC3"]],
            "meshes": [["primitives": Array(repeating: primitive, count: 32)]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(data.count < 4096)
        #expect(throws: NativeGLTFLoader.GLTFError.self) {
            _ = try NativeGLTFLoader(resourceRoot: root, maximumTotalBytes: 4096).load(data: data, baseURL: root)
        }
    }

    private func library() -> AnimationLibrary {
        .init(id: "test", binding: .init(sourceAsset: "Assets/Robot.glb", nodes: []), clips: [.init(id: "idle", name: "Idle", duration: 1)])
    }

    @Test func revokingToolCancelsRunningAndQueuedMutations() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let service = try #require(fixture.editor.workbench.animationService)
        let document = try service.create("Assets/Test.animlib", library: library())
        try document.save(expectedRevision: document.revision)
        let original = document.library
        let bytes = try Data(contentsOf: document.url)
        let directory = fixture.root.appendingPathComponent("Tools/Cancel")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
            @tool(id: "test.cancel", api: 2, platforms: ["macos", "windows"], permissions: ["editor.animations.read", "editor.animations.write"])
            class CancelTool {
                @export var revision = "";
                @export var submitted = 0;
                func activate(editor) { editor.addPanel(id: "main", title: "Cancel", location: "right", ui: "Panel.ui"); }
                func mutate(editor) {
                    editor.animations.submit(["action": "apply", "path": "Assets/Test.animlib", "expectedRevision": revision,
                        "operations": [["id": "rename", "kind": "clip.configure", "clipID": "idle", "name": "Late mutation"]]]);
                    submitted += 1;
                }
                func inspect(editor) { editor.animations.submit(["action": "inspect", "path": "Assets/Test.animlib"]); submitted += 1; }
            }
            """.write(to: directory.appendingPathComponent("Cancel.ada"), atomically: true, encoding: .utf8)
        try """
            format: ada.ui
            schemaVersion: 1
            inputs:
              - {name: revision, type: string, defaultValue: ''}
            actions:
              - {name: mutate}
              - {name: inspect}
            root:
              id: cancel
              type: Text
              arguments:
                text: {value: Cancellation test}
            """.write(to: directory.appendingPathComponent("Panel.ui"), atomically: true, encoding: .utf8)
        let gate = AnimationJobGate()
        let defaults = try #require(UserDefaults(suiteName: "AnimationCancel-\(UUID())"))
        // Suspend only scheduling; the resumed request still executes the real project service.
        let host = EditorStudioToolHost(defaults: defaults, animationExecutor: { request, workbench in
            if request.action == .apply { await gate.pause() }
            defer { gate.finished = true }
            return try await service.execute(request, workbench: workbench)
        })
        defer { gate.resume(); host.close() }
        host.open(projectURL: fixture.root, editor: fixture.editor)
        host.enable("test.cancel")
        host.approve(try #require(host.permissionRequest).id)
        let panel = try #require(host.selectedPanel)
        panel.session.context.set("revision", to: .string(document.revision))
        panel.session.context.perform("mutate")
        for _ in 0..<100 where !gate.started { await Task.yield() }
        #expect(gate.started)
        panel.session.context.perform("inspect")
        for _ in 0..<100 where panel.runtime.values["submitted"] != .int(2) { await Task.yield() }
        #expect(panel.runtime.values["submitted"] == .int(2))
        host.disable("test.cancel")
        gate.resume()
        for _ in 0..<100 where !gate.finished { await Task.yield() }
        #expect(gate.finished)
        #expect(document.library == original)
        #expect(try Data(contentsOf: document.url) == bytes)
    }

    @Test func detachedToolRequestsPreserveUTF8IncludingNull() throws {
        let source = AdaScriptSource(path: "Strings.ada", source: """
            @tool(id: "test.strings", api: 2, platforms: ["macos", "windows"], permissions: ["editor.animations.read"])
            class Strings {
                @export var path = "";
                func activate(editor) { editor.addPanel(id: "main", title: "Tests", location: "right", ui: "Panel.ui"); }
                func inspect(editor) { editor.animations.submit(["action": "inspect", "path": path]); }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        let path = "Assets/Кость.animlib\0suffix"
        _ = try runtime.perform("inspect", inputs: ["path": .string(path)], scene: nil)
        #expect(try #require(runtime.takeAnimationJobs().first).request.path == path)
    }

    @Test func libraryPreviewUsesBoundedImportBeforeGPUWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.root.appendingPathComponent("Assets/Oversized.gltf")
        // An unused accessor makes the unprotected baseline safe to run while still testing early inventory rejection.
        try Data(#"{"asset":{"version":"2.0"},"accessors":[{"componentType":5126,"count":1000000000,"type":"SCALAR"}]}"#.utf8).write(to: model)
        let preview = EditorModelAssetPreviewModel()
        defer { preview.cancel() }
        preview.load(path: model.path, resourceRoot: fixture.root.appendingPathComponent("Assets"))
        for _ in 0..<200 where preview.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!preview.isLoading)
        #expect(preview.asset == nil)
        #expect(preview.error == NativeGLTFLoader.GLTFError.bufferOutOfBounds.localizedDescription)
    }

    @Test func scopedImportRejectsPrimaryModelOutsideAssets() async throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let assets = fixture.root.appendingPathComponent("Assets").resolvingSymlinksInPath().standardizedFileURL
        let inside = assets.appendingPathComponent("Inside.gltf")
        let outside = fixture.root.appendingPathComponent("Outside.gltf")
        let data = Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        try data.write(to: inside)
        try data.write(to: outside)
        let loader = NativeGLTFLoader(resourceRoot: assets)
        _ = try await loader.load(url: inside)
        await #expect(throws: NativeGLTFLoader.GLTFError.invalidDataURI) { _ = try await loader.load(url: outside) }
    }

    @Test func openedModelIsAnAnimatorTargetWithoutAnySceneDocument() throws {
        let fixture = try makeFixture()
        defer { fixture.editor.studioTools.close(); try? FileManager.default.removeItem(at: fixture.root) }
        let workbench = fixture.editor.workbench
        workbench.openDocuments = []
        let model = EditorAssetDocument(id: "asset:Assets/Robot.glb", title: "Robot.glb", relativePath: "Assets/Robot.glb",
            absolutePath: fixture.root.appendingPathComponent("Assets/Robot.glb").path, assetReference: "@res://Robot.glb",
            kind: .model3D, fileExtension: "glb", byteCount: nil, modifiedAt: nil, errorMessage: nil)
        workbench.open(.asset(model))
        #expect(workbench.activeSceneDocument == nil)
        let target = try #require(fixture.editor.skeletalAnimationTarget)
        #expect(target.documentID == model.id)
        #expect(target.source.source == "@res://Robot.glb")
        #expect(target.entityID.isEmpty)
        #expect(fixture.editor.showBottomPanel)
        #expect(fixture.editor.toolStrip.activeLeftBottomTool == "animator")
    }

    private func makeFixture() throws -> (root: URL, editor: EditorViewModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationAuthoring-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Animation", buildSystem: .adaScript), at: root)
        let model = EditorSceneModel.default(projectName: "Animation")
        let content = try model.encodedYAML()
        let scene = root.appendingPathComponent("Assets/Main.ascn")
        try content.write(to: scene, atomically: true, encoding: .utf8)
        let editor = EditorViewModel(project: .init(name: "Animation", path: root.path), autosaveDelay: .milliseconds(10))
        editor.workbench.open(.scene(.init(id: "scene:Assets/Main.ascn", title: "Main.ascn", relativePath: "Assets/Main.ascn", absolutePath: scene.path,
            content: content, lastSavedContent: content, isReadOnly: false, sceneModel: model, errorMessage: nil, isDirty: false,
            statusMessage: nil, loadSummary: EditorSceneFileLoader.summary(from: content))))
        return (root, editor)
    }
}

@MainActor
private final class AnimationJobGate {
    var started = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
