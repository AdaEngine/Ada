@_spi(Internal) @testable import AdaApp
import AdaEngine
@testable import AdaScene
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Visual terrain runs the fixed pipeline without installing a physics backend")
    func terrainOptionalPhysicsScheduling() async throws {
        let app = try await makeApp()
        let owner = app.main.spawn("Visual terrain") {
            Transform(); Terrain3DSource(generatesCollision: false)
        }
        let requiresMissingSync = TerrainPhysicsReadinessSystem.dependencies.contains(.after(Physics3DSyncSystem.self))
        #expect(!requiresMissingSync, "Optional physics cannot be a required graph edge in a model-only app")
        // Establish the failure without entering the known scheduler assertion, then exercise
        // the actual registered phases once that mandatory dependency is removed.
        guard !requiresMissingSync else {
            return
        }
        await app.main.runScheduler(.preUpdate)
        await app.main.runScheduler(.physicsSync)
        await app.main.runScheduler(.physicsStep)
        await app.main.runScheduler(.physicsWriteback)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
