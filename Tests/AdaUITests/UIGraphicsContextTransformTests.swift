@testable import AdaUI
import Math
import Testing

@MainActor
@Suite("Graphics context local transforms")
struct UIGraphicsContextTransformTests {
    @Test
    func childTranslationUsesParentScale() {
        var context = UIGraphicsContext()
        context.setTransform(
            Transform3D(translation: [100, -50, 0])
                * Transform3D(scale: [2, 3, 1])
        )
        context.translateBy(x: 10, y: -5)

        #expect(abs(context.transform.origin.x - 120) < 0.001)
        #expect(abs(context.transform.origin.y + 65) < 0.001)
    }

    @Test(arguments: [Float(0.75), 1, 1.08, 1.2])
    func insetIconStaysCenteredWhenButtonScales(scale: Float) {
        var context = UIGraphicsContext()
        context.setTransform(
            Transform3D(translation: [100, -50, 0])
                * Transform3D(translation: [24, -24, 0])
                * Transform3D(scale: [scale, scale, 1])
                * Transform3D(translation: [-24, 24, 0])
        )
        context.translateBy(x: 12, y: -12)
        let iconCenter = context.transform * Vector4(12, -12, 0, 1)

        #expect(abs(iconCenter.x - 124) < 0.001)
        #expect(abs(iconCenter.y + 74) < 0.001)
    }

    @Test
    func localScalePreservesContextOrigin() {
        var context = UIGraphicsContext()
        context.translateBy(x: 100, y: -50)
        context.scaleBy(x: 2, y: 3)

        #expect(abs(context.transform.origin.x - 100) < 0.001)
        #expect(abs(context.transform.origin.y + 50) < 0.001)
    }

    @Test
    func localRotationPreservesContextOrigin() {
        var context = UIGraphicsContext()
        context.translateBy(x: 100, y: -50)
        context.rotate(by: .degrees(90))
        let point = context.transform * Vector4(10, 0, 0, 1)

        #expect(abs(point.x - 100) < 0.001)
        #expect(abs(point.y + 40) < 0.001)
    }

    @Test
    func concatenationUsesLocalCoordinates() {
        var context = UIGraphicsContext()
        context.translateBy(x: 100, y: -50)
        context.concatenate(Transform3D(scale: [2, 3, 1]))
        let point = context.transform * Vector4(10, -5, 0, 1)

        #expect(abs(point.x - 120) < 0.001)
        #expect(abs(point.y + 65) < 0.001)
    }
}
