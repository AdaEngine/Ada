import AdaScriptCompilerCore
import Testing

struct AdaScriptDecalCapabilitiesTests {
    @Test func infersWorldAccessForDecalOperations() throws {
        let source = AdaScriptCompilerSource(path: "Decals.ada", source: """
            @system(id: "place")
            class Place {
                func update(context) { context.world.placeDecal(1, "@res://Decal.png", [[0, 0, 0], [0, 0, 1], [1, 1, 1]], []); }
            }
            @system(id: "update")
            class Update {
                func update(context) { context.world.updateDecal(1, "handle", "@res://Decal.png", []); }
            }
            @system(id: "remove")
            class Remove {
                func update(context) { context.world.removeDecal(1, "handle"); }
            }
            @system(id: "read")
            class Read {
                func update(context) { context.world.decalResult("request"); }
            }
            """)
        let capabilities = try AdaScriptSchemaParser.parseSystemCapabilities(sources: [source])
        #expect(capabilities.count == 4)
        let worldCapabilities = capabilities.map(\.usesDeferredCommands)
        #expect(worldCapabilities == [true, true, true, true])
    }
}
