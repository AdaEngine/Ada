@_spi(AdaEngine) import AdaEngine

extension EditorSceneViewportView {
    var viewportCoordinateRulerLayer: some View {
        let revision = viewportRevision
        return GeometryReader { proxy in
            // A declaration is required inside AdaUI's result builder.
            // swiftlint:disable:next redundant_discardable_let
            let _ = revision
            let ruler = viewportModel.coordinateRuler(in: proxy.size)
            ZStack(anchor: .topLeading) {
                RectangleShape()
                    .fill(theme.editorColors.surface.opacity(0.92 * ruler.opacity))
                    .frame(width: proxy.size.width, height: 20)
                RectangleShape()
                    .fill(theme.editorColors.surface.opacity(0.92 * ruler.opacity))
                    .frame(width: 40, height: proxy.size.height)
                ForEach(ruler.labels, id: \.id) { label in
                    coordinateRulerLabel(label, opacity: ruler.opacity)
                }
                Text("X")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(red: 0.78, green: 0.24, blue: 0.28).opacity(ruler.opacity))
                    .frame(width: 16, height: 18)
                    .offset(x: max(40, proxy.size.width - 18), y: 1)
                Text("Y")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(red: 0.24, green: 0.60, blue: 0.31).opacity(ruler.opacity))
                    .frame(width: 16, height: 18)
                    .offset(x: 2, y: max(20, proxy.size.height - 20))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    func coordinateRulerLabel(
        _ label: EditorSceneViewportCoordinateRuler.Label,
        opacity: Float
    ) -> some View {
        switch label.axis {
        case .x:
            Text(label.text)
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.muted.opacity(opacity))
                .frame(width: 48, height: 18)
                .offset(x: label.position.x - 24, y: 1)
        case .y:
            Text(label.text)
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.muted.opacity(opacity))
                .frame(width: 34, height: 18, alignment: .trailing)
                .offset(x: 2, y: label.position.y - 9)
        }
    }
}
