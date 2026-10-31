@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Environment color correction authoring", .serialized)
struct EditorColorCorrectionTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func curvesSurviveSavingAndDecodeIntoTheRuntimeEnvironment() throws {
        let descriptor = EditorComponentRegistry.environment3DDescriptor
        let field = try #require(descriptor.fields.first { $0.key == "postProcess.colorGrading.curves" })
        #expect(field.groupPath == ["Color Correction"])
        var scene = EditorSceneModel.default(projectName: "Color Correction")
        let camera = scene.addEntity(name: "Camera", parentID: "root")
        scene.addComponent(typeName: descriptor.typeName, to: camera.id)
        let mode = try #require(descriptor.fields.first { $0.key == "postProcess.colorGrading.correctionMode" })
        scene.updateField(typeName: descriptor.typeName, field: mode, value: "curves", in: camera.id)
        let authored = ColorCurves3D(master: ColorCurve3D(points: [.init(0, 0), .init(0.4, 0.7), .init(1, 1)]))
        let json = String(decoding: try JSONEncoder().encode(authored), as: UTF8.self)
        scene.updateField(typeName: descriptor.typeName, field: field, value: json, in: camera.id)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Main.ascn")
        try scene.encodedYAML().write(to: url, atomically: true, encoding: .utf8)
        let restored = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let payload = try #require(restored.entities.first { $0.id == camera.id }?.components[descriptor.typeName])
        let environment = try #require(try descriptor.decode(payload) as? Environment3D)
        #expect(environment.colorCorrectionMode == .curves)
        #expect(environment.postProcess.colorGrading.curves == authored)
    }

    @Test func projectLUTLoadsAfterSceneResolutionAndMissingAssetsStayNeutral() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Image(width: 256, height: 16, color: .white).writePNG(to: directory.appendingPathComponent("Look.png"))
        let descriptor = EditorComponentRegistry.environment3DDescriptor
        let field = try #require(descriptor.fields.first { $0.key == "postProcess.colorGrading.lut" })
        var payload = descriptor.makeDefaultPayload()
        field.write("@res://Look.png", to: &payload)
        let resolved = try EditorSceneFileLoader.resolvedComponentPayload(
            typeName: descriptor.typeName, payload: payload, sourceURL: directory.appendingPathComponent("Main.ascn"), resourceRootURL: directory
        )
        let environment = try #require(try descriptor.decode(resolved) as? Environment3D)
        #expect(environment.postProcess.colorGrading.lut?.asset?.width == 256)
        #expect(environment.postProcess.colorGrading.lut?.asset?.height == 16)
        field.write(directory.appendingPathComponent("Missing.png").path, to: &payload)
        let missing = try #require(try descriptor.decode(payload) as? Environment3D)
        #expect(missing.postProcess.colorGrading.lut == nil)
        field.write("@res://../Outside.png", to: &payload)
        #expect(throws: (any Error).self) {
            try EditorSceneFileLoader.resolvedComponentPayload(
                typeName: descriptor.typeName, payload: payload, sourceURL: directory.appendingPathComponent("Main.ascn"), resourceRootURL: directory
            )
        }
    }

    @Test func modeSwitchKeepsOnlyItsOwnControlsVisible() {
        let prefix = "postProcess.colorGrading."
        #expect(EditorColorCorrectionFields.isVisible(prefix + "curves", mode: "curves"))
        #expect(!EditorColorCorrectionFields.isVisible(prefix + "lut", mode: "curves"))
        #expect(!EditorColorCorrectionFields.isVisible(prefix + "curves", mode: "lut"))
        #expect(EditorColorCorrectionFields.isVisible(prefix + "lut", mode: "lut"))
        #expect(!EditorColorCorrectionFields.isVisible(prefix + "lutIntensity", mode: "disabled"))
    }

    @Test func mountedCurveDragCommitsOnceAndFitsBothLanguages() async throws {
        var value = String(decoding: try JSONEncoder().encode(ColorCurves3D()), as: UTF8.self)
        var commits = 0
        let binding = Binding(get: { value }, set: { value = $0; commits += 1 })
        let container = UIContainerView(rootView: EditorColorCurvesField(text: binding).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 300, height: 310)
        container.bounds.size = container.frame.size
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
            let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ColorCorrection.Curve"))
            #expect(node.absoluteFrame.size.width <= 300)
            #expect(node.absoluteFrame.size.width > 200)
            #expect(node.absoluteFrame.maxY <= 310)
        }
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ColorCorrection.Curve")).absoluteFrame
        let start = Point(frame.minX + 2, frame.maxY - 2)
        let end = Point(frame.minX + 2, frame.minY + frame.size.height * 0.6)
        container.onMouseEvent(.init(window: .empty, button: .left, mousePosition: start, phase: .began, modifierKeys: [], time: 0))
        container.onMouseEvent(.init(window: .empty, button: .left, mousePosition: end, phase: .changed, modifierKeys: [], time: 0.1))
        #expect(commits == 0)
        container.onMouseEvent(.init(window: .empty, button: .left, mousePosition: end, phase: .ended, modifierKeys: [], time: 0.2))
        #expect(commits == 1)
        let edited = try JSONDecoder().decode(ColorCurves3D.self, from: Data(value.utf8))
        #expect(edited.master.points[0].output > 0.2)
        #expect(edited.red == ColorCurve3D())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ColorCorrection-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
