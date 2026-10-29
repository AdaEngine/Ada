@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI

struct EditorSceneViewportOrientationCompass: View {
    let viewportModel: EditorSceneViewportModel
    let presentation: EditorViewportPresentation

    private let diameter: Float = 120
    private let axisLength: Float = 44
    private let axisLineWidth: Float = 4.5

    var body: some View {
        // The compass has fixed geometry. Read the presented camera during drawing,
        // so rotation never schedules a layout of the surrounding editor panels.
        Canvas(drawingRevision: { presentation.presentedAnnotations?.generation ?? (UInt64.max - UInt64(presentation.revision)) }) { context, _ in
            let axes = compassAxes()
            let center = Vector2(diameter * 0.5, diameter * 0.5)
            for axis in axes {
                let positive = Vector2(
                    center.x + axis.positive.x * axisLength,
                    center.y - axis.positive.y * axisLength
                )
                let negative = Vector2(
                    center.x - axis.positive.x * axisLength,
                    center.y + axis.positive.y * axisLength
                )
                context.drawLine(
                    start: Vector2(center.x, -center.y),
                    end: Vector2(positive.x, -positive.y),
                    lineWidth: axisLineWidth,
                    color: axis.color.opacity(0.78 + max(0, axis.cameraDepth) * 0.22)
                )
                context.drawLine(
                    start: Vector2(center.x, -center.y),
                    end: Vector2(negative.x, -negative.y),
                    lineWidth: axisLineWidth,
                    color: axis.color.opacity(0.38 + max(0, -axis.cameraDepth) * 0.22)
                )
                context.drawEllipse(
                    in: Rect(x: negative.x - 11, y: negative.y - 11, width: 22, height: 22),
                    color: axis.color.opacity(0.42 + max(0, -axis.cameraDepth) * 0.36)
                )
            }
            for (index, axis) in axes.enumerated() {
                let point = Vector2(center.x + axis.positive.x * axisLength, center.y - axis.positive.y * axisLength)
                context.drawEllipse(in: Rect(x: point.x - 15, y: point.y - 15, width: 30, height: 30), color: axis.color)
                context.drawContents(of: Self.axisLabels[index],
                                     transform: context.transform * Transform3D(translation: [point.x - 15, -point.y + 15, 0]))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityIdentifier("AdaEditor.SceneViewport.OrientationCompass")
    }

    private static let axisLabels: [UIGraphicsContext] = ["X", "Y", "Z"].map { (name: String) -> UIGraphicsContext in
        var attributes = TextAttributeContainer()
        attributes.font = .system(size: 15, weight: .semibold)
        attributes.foregroundColor = Color.fromHex(0x16191D)
        let layout = TextLayoutManager()
        layout.setTextContainer(TextContainer(text: AttributedText(name, attributes: attributes)))
        layout.fitToSize(Size(width: 30, height: 30))
        var minimum = Vector2(.infinity, .infinity), maximum = Vector2(-.infinity, -.infinity)
        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    minimum = min(minimum, Vector2(glyph.position.x, glyph.position.y))
                    maximum = max(maximum, Vector2(glyph.position.z, glyph.position.w))
                }
            }
        }
        var context = UIGraphicsContext()
        if minimum.x.isFinite, maximum.x.isFinite {
            let center = (minimum + maximum) * 0.5
            context.translateBy(x: 15 - center.x, y: -15 - center.y)
            for line in layout.textLines { context.draw(line) }
        }
        context.commitDraw()
        return context
    }

    private func compassAxes() -> [CompassAxis] {
        let orientation = presentation.compassOrientation
        let right = orientation?.right ?? viewportModel.right3D
        let up = orientation?.up ?? viewportModel.up3D
        let front = orientation?.front ?? viewportModel.front3D

        return [
            axis("X", color: Color.fromHex(0xF44364), direction: Vector3(1, 0, 0), right: right, up: up, front: front),
            axis("Y", color: Color.fromHex(0x80D400), direction: Vector3(0, 1, 0), right: right, up: up, front: front),
            axis("Z", color: Color.fromHex(0x1689F8), direction: Vector3(0, 0, 1), right: right, up: up, front: front)
        ]
    }

    private func axis(
        _ name: String,
        color: Color,
        direction: Vector3,
        right: Vector3,
        up: Vector3,
        front: Vector3
    ) -> CompassAxis {
        CompassAxis(
            name: name,
            color: color,
            positive: Vector2(
                direction.x * right.x + direction.y * right.y + direction.z * right.z,
                direction.x * up.x + direction.y * up.y + direction.z * up.z
            ),
            cameraDepth: direction.x * front.x + direction.y * front.y + direction.z * front.z
        )
    }
}

private struct CompassAxis: Identifiable {
    let name: String
    let color: Color
    let positive: Vector2
    let cameraDepth: Float

    var id: String { name }
}
