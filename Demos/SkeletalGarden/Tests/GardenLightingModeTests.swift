@testable import SkeletalGarden
import Testing

@Suite
struct GardenLightingModeTests {
    @Test
    func normalAndTemporalLaunchesIncludeColoredSources() {
        #expect(GardenLightingMode.usesLocalLights(arguments: []))
        #expect(GardenLightingMode.usesLocalLights(arguments: ["--temporal"]))
        #expect(GardenLightingMode.usesLocalLights(arguments: ["--no-local-lights"]))
        #expect(!GardenLightingMode.usesLocalLights(arguments: ["--daylight"]))
        #expect(GardenLightingMode.usesLocalLights(arguments: ["--daylight", "--local-lights"]))
    }
}
