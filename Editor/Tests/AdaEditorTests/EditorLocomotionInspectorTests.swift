@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("3D Locomotion inspector")
struct EditorLocomotionInspectorTests {
    @Test("GardenRobot settings are editable and survive scene save and reopen")
    func editsRoundTrip() throws {
        EditorComponentRegistry.registerBuiltIns()
        let typeName = String(reflecting: CharacterLocomotion3DComponent.self)
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: typeName))
        #expect(descriptor.displayName == "3D Locomotion")

        var scene = EditorSceneModel.default(projectName: "GardenRobot")
        let robot = scene.addEntity(preset: .empty)
        scene.addComponent(typeName: typeName, to: robot.id)

        let edits = [
            ("configuration.clips.walk", "Run"),
            ("configuration.facingMode", "keepFacing"),
            ("configuration.left.walk", "Walk"),
            ("configuration.walkReferenceSpeed", "1.4"),
        ]
        for (key, value) in edits {
            let field = try #require(descriptor.fields.first { $0.key == key && $0.isEditable })
            scene.updateField(typeName: typeName, field: field, value: value, in: robot.id)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locomotion-\(UUID().uuidString).ascn")
        defer { try? FileManager.default.removeItem(at: url) }
        try scene.encodedYAML().write(to: url, atomically: true, encoding: .utf8)
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let payload = try #require(reopened.entities.first { $0.id == robot.id }?.components[typeName])
        let component = try #require(EditorComponentRegistry.decode(typeName: typeName, payload: payload) as? CharacterLocomotion3DComponent)
        #expect(component.isEnabled)
        #expect(component.configuration.clips.walk == "Run")
        #expect(component.configuration.clips.land == "Land")
        #expect(component.configuration.facingMode == .keepFacing)
        #expect(component.configuration.left.walk == "Walk")
        #expect(component.configuration.left.run == nil)
        #expect(component.configuration.walkReferenceSpeed == 1.4)
    }
}
