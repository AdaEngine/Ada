import AdaApp
@_spi(Internal) import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaUtils
import Testing

@Suite("Pipelined render world isolation")
struct PipelinedRenderWorldTests {
    @Test("A pipelined render world loses the main-world reference after extraction", arguments: [false, true])
    @MainActor
    func mainWorldReferenceEndsAtExtraction(pipelined: Bool) async throws {
        unsafe RenderEngine.configurations.preferredBackend = .headless
        let app = AppWorlds(main: World(name: "PipelinedExtraction"))
        app.addPlugin(RenderWorldPlugin())
        MainSchedulerPlugin().setup(in: app)
        app.insertResource(PrimaryWindowId(windowId: RID()))
        app.insertResource(OffscreenRenderWorld())
        // Plugins set up during build, so the render world exists only afterwards.
        try await app.build()
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld))
        renderWorld.insertResource(RenderPipelining(isEnabled: pipelined))

        try await app.update()
        try await app.waitForPipelinedUpdates()
        #expect((renderWorld.main.getResource(MainWorld.self) != nil) == !pipelined)
    }

    @Test("Material snapshots are reused until the material changes")
    func materialSnapshotTracksRevisions() {
        let material = PBRMaterial()
        material.baseColorFactor = [0.2, 0.4, 0.6, 1]
        material.roughnessFactor = 0.3
        let first = material.renderSnapshot()
        #expect(first !== material)
        #expect(first.snapshotSource === material)
        #expect(first.baseColorFactor == material.baseColorFactor && first.roughnessFactor == 0.3)
        #expect(material.renderSnapshot() === first)

        // Edits for the next frame never reach the snapshot that is being rendered.
        material.roughnessFactor = 0.9
        #expect(first.roughnessFactor == 0.3)
        let second = material.renderSnapshot()
        #expect(second !== first)
        #expect(second.roughnessFactor == 0.9)
    }

    @Test("Every stored material property invalidates the snapshot")
    func untrackedPropertiesStillInvalidate() {
        let material = PBRMaterial()
        let first = material.renderSnapshot()
        // Not part of the PBR uniform block, so it does not change `uniformRevision`.
        material.metallicFactor = 0.25
        #expect(material.renderSnapshot() !== first)
        #expect(material.renderSnapshot().metallicFactor == 0.25)
    }
}
