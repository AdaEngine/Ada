@testable import AdaRender
import Testing

/// `CircleCanvasMaterial` uploads one struct into its shader block. The block is found by its name and the struct must
/// match the shader's byte layout, so both are pinned here.
@Suite("Circle canvas material")
struct CircleCanvasMaterialTests {
    @Test func parametersMatchTheShaderBlockLayout() {
        typealias Parameters = CircleCanvasMaterial.Parameters
        #expect(MemoryLayout<Parameters>.stride == 32)
        #expect(MemoryLayout<Parameters>.offset(of: \.fade) == 0)
        #expect(MemoryLayout<Parameters>.offset(of: \.thickness) == 4)
        #expect(MemoryLayout<Parameters>.offset(of: \.color) == 16)
    }

    @Test func initialValuesAndAccessorsReachTheParameters() {
        var material = CircleCanvasMaterial(thickness: 0.25, fade: 0.05, color: .red)
        #expect(material.thickness == 0.25)
        #expect(material.fade == 0.05)
        #expect(material.color == .red)
        material.thickness = 0.5
        #expect(material.parameters.thickness == 0.5)
    }
}
