@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
struct EditorScenarioComponentSnapshotTests {
    @Test func preservesDistinctRuntimeSchemasAndEveryNamedField() throws {
        let world = World()
        let player = RuntimeComponentDescriptor(stableID: "fixture.player", name: "Player", aliases: ["OldPlayer"],
            fieldNames: ["health", "grounded", "name", "inventory", "nullable"],
            fieldKinds: [.float, .bool, .string, .readOnly, .optional(.string)],
            defaultValues: [.double(89), .bool(true), .string("Vera"), .array([.int(7), .int(9)]), .null])
        let quest = RuntimeComponentDescriptor(stableID: "fixture.quest", name: "Quest",
            fieldNames: ["completed"], defaultValues: [.bool(false)])
        world.registerRuntimeComponent(player)
        world.registerRuntimeComponent(quest)
        let entity = world.spawn()
        entity.components += player.makeDefault()
        entity.components += quest.makeDefault()
        let captured = EditorScenarioComponentSnapshot.read(in: world, entity: entity.id, matching: [])
        let fields = try #require(captured.fields["fixture.player"])
        #expect(fields["health"] as? Double == 89)
        #expect(fields["grounded"] as? Bool == true)
        #expect(fields["name"] as? String == "Vera")
        #expect((fields["inventory"] as? [Int]) == [7, 9])
        #expect(fields["nullable"] is NSNull)
        #expect(captured.fields["fixture.quest"]?["completed"] as? Bool == false)
        #expect(JSONSerialization.isValidJSONObject(captured.fields))
        let filtered = EditorScenarioComponentSnapshot.read(in: world, entity: entity.id, matching: ["oldplayer"])
        #expect(Set(filtered.fields.keys) == ["fixture.player"])
    }

    @Test func acceptsQualifiedNativeNamesAndKeepsStructuredVectors() throws {
        Transform.registerComponent()
        let world = World()
        let entity = world.spawn { Transform(position: [1, 2, 3]) }
        let captured = EditorScenarioComponentSnapshot.read(in: world, entity: entity.id, matching: ["adatransform.transform"])
        #expect(captured.summaries["Transform"] != nil)
        let fields = try #require(captured.fields["AdaTransform.Transform"])
        #expect(fields["position"] as? [Double] == [1, 2, 3])
    }

    @Test func includesReadOnlyNativeRuntimeStatus() throws {
        MouseCaptureComponent.registerComponent()
        let world = World()
        let entity = world.spawn { MouseCaptureComponent(isRequested: true) }
        let captured = EditorScenarioComponentSnapshot.read(in: world, entity: entity.id, matching: [])
        let fields = try #require(captured.fields["AdaInput.MouseCaptureComponent"])
        #expect(fields["isRequested"] as? Bool == true)
        #expect(fields["isCaptured"] as? Bool == false)
    }
}
