@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
extension EditorScenePerformanceRegressionTests {
    @Test("Hierarchy resources survive mixed arrays and resource-named ancestors alongside large numeric geometry")
    func hierarchyResourcesWithNumericGeometry() throws {
        var model = EditorSceneModel.default(projectName: "Geometry")
        let entity = model.addEntity(name: "Mesh")
        let index = try #require(model.entities.firstIndex { $0.id == entity.id })
        model.entities[index].components["Game.Geometry"] = [
            "vertices": .array(Array(repeating: .array([.double(1), .double(2), .double(3)]), count: 100_000)),
            "comments": .array([.string("ordinary text"), .string("Assets/icon.png")]),
            "layers": .array([.object(["texture": .string("res://wall.png")]), .bool(false), .int(42),
                .object(["path": .array([.string("Assets/step.wav"), .null])])]),
            "metadata": .object(["material": .object(["label": .string("stone")]), "weight": .double(0.5)])
        ]
        let rows = EditorSceneHierarchyModel.visibleItems(for: model)
        let row = try #require(rows.first { $0.id == entity.id })
        #expect(row.resources == [
            .init(componentName: "Geometry", fieldName: "1", value: "Assets/icon.png"),
            .init(componentName: "Geometry", fieldName: "texture", value: "res://wall.png"),
            .init(componentName: "Geometry", fieldName: "0", value: "Assets/step.wav"),
            .init(componentName: "Geometry", fieldName: "label", value: "stone")
        ])
    }

    @Test("Profile hierarchy preparation in a real scene", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_PERF_SCENE"] != nil))
    func realSceneHierarchyPreparation() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_PERF_SCENE"])
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let clock = ContinuousClock()
        let decodeStart = clock.now
        let model = try EditorSceneModel.decode(from: content)
        let decodeDuration = decodeStart.duration(to: clock.now)
        let rowsStart = clock.now
        let rows = EditorSceneHierarchyModel.visibleItems(for: model)
        let rowsDuration = rowsStart.duration(to: clock.now)
        let document = EditorSceneDocument(id: "scene:benchmark", title: "Benchmark.ascn", relativePath: "Benchmark.ascn",
            content: content, sceneModel: model, isDirty: false, loadSummary: .init(entityCount: model.entities.count, warnings: []))
        let mountStart = clock.now
        let container = UIContainerView(rootView: EditorSceneHierarchySidebar(document: document, presentation: .embedded,
            onSelectEntity: { _ in }, onToggleEntityExpanded: { _ in }))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let mountDuration = mountStart.duration(to: clock.now)
        #expect(!rows.isEmpty)
        #expect(try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.SceneHierarchy")).absoluteFrame.width > 0)
        print("Hierarchy benchmark: bytes=\(content.utf8.count), entities=\(model.entities.count), decode=\(decodeDuration), rows=\(rowsDuration), mount=\(mountDuration)")
    }
}
