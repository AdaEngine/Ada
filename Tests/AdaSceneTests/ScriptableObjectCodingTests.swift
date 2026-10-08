import AdaECS
import AdaScene
import AdaUtils
import Foundation
import Testing

@Suite("Scriptable object coding", .serialized)
struct ScriptableObjectCodingTests {
    @Test("Round trips stable type, version, alias, and exported payload")
    @MainActor
    func roundTripsEnvelope() throws {
        try ScriptableObjectRegistry.register(
            CodingPlayerScript.self,
            identifier: "test.player-controller",
            version: 2,
            aliases: ["LegacyPlayerController"]
        )
        ScriptableComponents.registerComponent()
        let script = CodingPlayerScript()
        script.speed = 12
        let encoded = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let scripts = try #require(json["scripts"] as? [[String: Any]])
        let envelope = try #require(scripts.first)
        let payload = try #require(envelope["payload"] as? [String: Any])

        #expect(envelope["type"] as? String == "test.player-controller")
        #expect(envelope["version"] as? Int == 2)
        #expect(payload["speed"] as? Double == 12)

        let aliasJSON = """
        {"scripts":[{"type":"LegacyPlayerController","version":1,"payload":{"speed":7.5}}]}
        """
        let decoded = try JSONDecoder().decode(
            ScriptableComponents.self,
            from: Data(aliasJSON.utf8)
        )
        let decodedScript = try #require(decoded.scripts.first as? CodingPlayerScript)
        #expect(decodedScript.speed == 7.5)

        let futureJSON = """
        {"scripts":[{"type":"test.player-controller","version":99,"payload":{}}]}
        """
        #expect(
            throws: ScriptableObjectCodingError.unsupportedVersion(
                encoded: 99,
                current: 2,
                type: "test.player-controller"
            )
        ) {
            try JSONDecoder().decode(ScriptableComponents.self, from: Data(futureJSON.utf8))
        }

        let world = World(name: "Scriptable scene coding")
        let entity = world.spawn {
            ScriptableComponents(scripts: [script])
        }
        let encodedEntity = try JSONEncoder().encode(entity)
        let decodedEntity = try JSONDecoder().decode(Entity.self, from: encodedEntity)
        let decodedScripts = try #require(
            decodedEntity.components[ScriptableComponents.self]?.scripts
        )
        #expect((decodedScripts.first as? CodingPlayerScript)?.speed == 12)
    }

    @Test("Reports an unknown stable type")
    func rejectsUnknownType() {
        let json = """
        {"scripts":[{"type":"missing.script","version":1,"payload":{}}]}
        """
        #expect(throws: ScriptableObjectCodingError.unknownType("missing.script")) {
            try JSONDecoder().decode(ScriptableComponents.self, from: Data(json.utf8))
        }
    }
}

private final class CodingPlayerScript: ScriptableObject, @unchecked Sendable {
    @Export var speed = 8.0
}
