@_spi(Internal) import AdaApp
@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Testing

@testable import AdaEditor

@Component
private struct GroupedInspectorSettings: Codable, Sendable {
    @Export(group: "Camera/Auto Exposure") var speed: Float = 2
    @Export(group: "One/Two/Three/Four") var enabled: Bool = true
    var ungrouped: Int = 7
}

@Suite("Inspector groups and hierarchy", .serialized)
struct EditorInspectorGroupTests {
    @Test func nativeMacroPreservesExplicitPathsAndFlatPayload() throws {
        let descriptor = GroupedInspectorSettings.componentDescriptor
        #expect(descriptor.fields.map(\.groupPath) == [["Camera", "Auto Exposure"], ["One", "Two", "Three", "Four"], []])
        let settings = GroupedInspectorSettings()
        let defaultsData = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(GroupedInspectorSettings.self, from: defaultsData)
        #expect(restored.speed == 2)
        #expect(restored.enabled)
        let restoredAgain = try JSONDecoder().decode(GroupedInspectorSettings.self, from: JSONEncoder().encode(restored))
        #expect(restoredAgain.speed == 2)
        let changed = try #require(descriptor.writing(.double(3), toField: "speed", in: settings) as? GroupedInspectorSettings)
        #expect(changed.speed == 3)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
        #expect(json["speed"] as? Double == 3)
        #expect(json["Camera"] == nil)
    }

    @Test @MainActor func scriptAnnotationsReachEditorCatalogs() throws {
        let source = AdaScriptCompilerSource(
            path: "Settings.ada",
            source: """
                @component(id: "test.settings") struct Settings {
                    @export(group: "Camera/Auto Exposure") var speed = 2.0;
                    @export var autoExposureMinimum = -4.0;
                }
                @scriptable(id: "test.camera") class TestCamera {
                    @export(group: "One/Two/Three/Four") var enabled = true;
                }
                """)
        let schemas = try AdaScriptSchemaParser.parse(sources: [source])
        let fields = try #require(EditorScriptComponentCatalog.makeComponents(from: schemas).first?.descriptor.fields)
        #expect(fields.map(\.groupPath) == [["Camera", "Auto Exposure"], []])
        #expect(fields.map(\.key) == ["speed", "autoExposureMinimum"])
        let scriptables = try AdaScriptSchemaParser.parseScriptables(sources: [source])
        #expect(scriptables.first?.fields.first?.groupPath == ["One", "Two", "Three", "Four"])
        let result = try EditorScriptableObjectCatalogLoader.makeResult(project: AdaProject(schemaVersion: 3), sources: [source])
        #expect(result.descriptors.first?.fields.first?.groupPath == ["One", "Two", "Three", "Four"])
        let catalog = try result.playRuntime.makeScriptableCatalog()
        let app = AppWorlds(main: World())
        InputPlugin(actions: []).setup(in: app)
        EditorProjectScriptObjectsPlugin(catalog: catalog).setup(in: app)
        defer { ScriptableObjectRegistry.removeScope(app.executionID) }
        let script = try app.withExecutionContext { try ScriptableObjectRegistry.make(named: "test.camera") }
        #expect(script.readExportedField("enabled") == .bool(true))
    }

    @Test(arguments: ["A/B/C/D/E", "", "A//B", " A/ /B", "/A"])
    func rejectsInvalidGroupPaths(_ path: String) {
        let source = AdaScriptCompilerSource(
            path: "Bad.ada",
            source: """
                @component(id: "test.bad") struct Bad {
                    @export(group: "\(path)") var value = 1;
                }
                """)
        #expect(throws: AdaScriptSchemaError.self) { try AdaScriptSchemaParser.parse(sources: [source]) }
    }

    @Test func groupsReuseTheirSectionAndCollapseWholeSubtrees() {
        let fields = [
            EditorComponentField(key: "one", label: "One", kind: .float, groupPath: ["Camera", "Exposure"]),
            EditorComponentField(key: "plain", label: "Auto Exposure", kind: .float),
            EditorComponentField(key: "two", label: "Two", kind: .float, groupPath: ["Camera", "Exposure"]),
            EditorComponentField(key: "deep", label: "Deep", kind: .bool, groupPath: ["A", "B", "C", "D", "E"]),
        ]
        let rows = EditorInspectorFieldLayout.rows(fields: fields)
        #expect(rows.filter { $0.groupPath == ["Camera", "Exposure"] }.count == 1)
        #expect(rows.compactMap(\.fieldIndex) == [0, 2, 1, 3])
        #expect(rows.map(\.level).max() == 4)
        let collapsed = EditorInspectorFieldLayout.rows(fields: fields, collapsed: ["Camera"])
        #expect(collapsed.compactMap(\.fieldIndex) == [1, 3])
        #expect(EditorInspectorFieldLayout.rows(fields: fields).filter { $0.id == "field:plain" }.first?.level == 0)
    }

    @Test func searchFindsCollapsedDescendantsWithoutChangingSceneState() throws {
        var scene = EditorSceneModel.default(projectName: "Search")
        let parent = scene.addEntity(name: "Оружие", parentID: "root")
        let camera = scene.addEntity(name: "Камера игрока", parentID: parent.id)
        _ = scene.addEntity(name: "Other", parentID: "root")
        scene.editor?.expandedEntities = []
        let before = scene
        let found = EditorSceneHierarchyModel.visibleItems(for: scene, query: "  КАМЕРА  ")
        #expect(found.map(\.id) == ["root", parent.id, camera.id])
        #expect(found.map(\.level) == [0, 1, 2])
        #expect(EditorSceneHierarchyModel.visibleItems(for: scene, query: "missing").isEmpty)
        #expect(EditorSceneHierarchyModel.visibleItems(for: scene).map(\.id) == ["root"])
        #expect(scene == before)
    }

    @Test func neutralParentGroupingSurvivesSceneRoundTripAndRejectsCycles() throws {
        var scene = EditorSceneModel.default(projectName: "Groups")
        let entity = scene.addEntity(name: "Sound", parentID: "root")
        let group = scene.addEntity(name: "Weapon Audio", parentID: "root")
        let payload = try #require(scene.entities.first { $0.id == entity.id }?.components)
        let reparented = scene.reparentEntity(entity.id, to: group.id)
        #expect(reparented)
        let cycleAccepted = scene.reparentEntity(group.id, to: entity.id)
        #expect(!cycleAccepted)
        let restored = try EditorSceneModel.decode(from: scene.encodedYAML())
        #expect(restored.entities.first { $0.id == entity.id }?.parent == group.id)
        #expect(restored.entities.first { $0.id == entity.id }?.components == payload)
    }

    @Test func hierarchyResizeKeepsSpaceForTheViewport() {
        #expect(EditorSceneHierarchyLayout.width(100, available: 1000) == 180)
        #expect(EditorSceneHierarchyLayout.width(800, available: 1000) == 520)
        #expect(EditorSceneHierarchyLayout.width(520, available: 600) == 352)
        #expect(EditorSceneHierarchyLayout.width(220, available: 100) == 0)
    }

    @Test func importedTopLevelEntitiesCanBeGroupedIncludingTheFirstOne() {
        var scene = EditorSceneModel.default(projectName: "Imported")
        let group = scene.addEntity(name: "Player Group", parentID: nil)
        let moved = scene.reparentEntity("root", to: group.id)
        #expect(moved)
        #expect(scene.entities.first { $0.id == "root" }?.parent == group.id)
        #expect(scene.isRootEntity(group.id))
    }

    @Test @MainActor func environmentGroupsRetainNestedValuesAndRenderFoldouts() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let descriptor = EditorComponentRegistry.environment3DDescriptor
        let minimum = try #require(descriptor.fields.first { $0.key == "postProcess.autoExposure.minimumEV" })
        #expect(minimum.groupPath == ["Auto Exposure"])
        var payload = descriptor.makeDefaultPayload()
        minimum.write("-3.5", to: &payload)
        #expect(minimum.displayValue(in: payload) == "-3.5")
        #expect(payload["Auto Exposure"] == nil)
        let decoded = try #require(try descriptor.decode(payload) as? Environment3D)
        #expect(decoded.postProcess.autoExposure.minimumEV == -3.5)
        let inspector = EditorInspectorSidebarViewModel()
        inspector.selectEntity(
            .init(
                editorID: "camera", name: "Camera", componentNames: [], transformFields: [],
                components: [
                    .init(
                        typeName: descriptor.typeName, displayName: descriptor.displayName,
                        fields: descriptor.fields.map { .init(typeName: descriptor.typeName, field: $0, value: $0.displayValue(in: payload)) },
                        canRemove: true)
                ], addableComponents: [], gizmo: nil, hasExplicitGizmo: false))
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 380, height: 1800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Group.\(descriptor.typeName).Auto Exposure")
        let fieldSelector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Value.\(descriptor.typeName).\(minimum.key)")
        _ = try container.uiScrollToNode(matching: selector)
        func renderedFillColors() -> Set<Color> {
            let context = UIGraphicsContext()
            container.draw(in: container.bounds, with: context)
            return Set(context.getDrawCommands().compactMap { command in
                switch command {
                case let .drawPath(_, _, .fill(color)), let .drawQuad(_, _, color): color
                default: nil
                }
            })
        }
        let tint = EditorInspectorGroupColor.tint(for: "\(descriptor.typeName)/group:Auto Exposure")
        let bloomTint = EditorInspectorGroupColor.tint(for: "\(descriptor.typeName)/group:Bloom")
        #expect(tint != bloomTint)
        #expect(renderedFillColors().contains(tint.opacity(0.18)))
        #expect(!container.uiFindNodes(matching: fieldSelector).isEmpty)
        _ = try container.uiTapNode(matching: selector)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(1))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(!container.uiFindNodes(matching: selector).isEmpty)
        #expect(container.uiFindNodes(matching: fieldSelector).isEmpty)
        #expect(renderedFillColors().contains(tint.opacity(0.18)))
        _ = try container.uiTapNode(matching: selector)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(1))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(!container.uiFindNodes(matching: fieldSelector).isEmpty)
        // Collapsing changes presentation only; a live binding still addresses the same nested field.
        #expect(inspector.componentFieldBinding(typeName: descriptor.typeName, field: minimum).wrappedValue == "-3.5")
        EditorLocalization.shared.preference = .russian
        for _ in 0..<5 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(L10n.tr("Auto Exposure") == "Автоэкспозиция")
        let translatedHeader = try container.uiNode(matching: selector)
        #expect(translatedHeader.absoluteFrame.width <= 380)
        #expect(translatedHeader.absoluteFrame.height >= 30)
        #expect(renderedFillColors().contains(tint.opacity(0.18)))
    }
}
