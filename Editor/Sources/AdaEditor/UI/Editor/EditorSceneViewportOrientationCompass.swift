@_spi(AdaEngine) import AdaEngine

struct EditorSceneViewportOrientationCompass: View {
    let viewportModel: EditorSceneViewportModel

    private let diameter: Float = 120
    private let axisLength: Float = 44
    private let axisLineWidth: Float = 4.5

    var body: some View {
        let axes = compassAxes()

        ZStack(anchor: .topLeading) {
            Canvas { context, _ in
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
            }
            .frame(width: diameter, height: diameter)

            ForEach(axes) { axis in
                Text(axis.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.fromHex(0x16191D))
                    .frame(width: 30, height: 30)
                    .background(CircleShape().fill(axis.color))
                    .offset(
                        x: diameter * 0.5 + axis.positive.x * axisLength - 15,
                        y: diameter * 0.5 - axis.positive.y * axisLength - 15
                    )
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityIdentifier("AdaEditor.SceneViewport.OrientationCompass")
    }

    private func compassAxes() -> [CompassAxis] {
        let right = viewportModel.right3D
        let up = viewportModel.up3D
        let front = viewportModel.front3D

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
