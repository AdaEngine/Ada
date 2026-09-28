#if os(iOS)
@_spi(AdaEngine) import AdaEngine

/// Small vector controls independent of the editor's subset of icon-font glyphs.
struct MobileEditorPromptSymbol: View {
    enum Kind {
        case microphone
        case expand
        case collapse
    }

    @Environment(\.theme) private var theme
    let kind: Kind

    var body: some View {
        ZStack {
            if kind == .microphone {
                RoundedRectangleShape(cornerRadius: 4)
                    .fill(theme.editorColors.text)
                    .frame(width: 8, height: 13)
                    .offset(y: -4)
            }
            SymbolShape(kind: kind)
                .stroke(theme.editorColors.text, lineWidth: 2)
        }
        .frame(width: 24, height: 24)
    }

    private struct SymbolShape: Shape {
        typealias AnimatableData = EmptyAnimatableData
        let kind: Kind

        func path(in rect: Rect) -> Path {
            var path = Path()
            func point(_ x: Float, _ y: Float) -> Point {
                Point(rect.minX + x / 24 * rect.width, rect.minY + y / 24 * rect.height)
            }
            switch kind {
            case .microphone:
                path.move(to: point(5, 10))
                path.addLine(to: point(5, 12))
                path.addQuadCurve(to: point(12, 19), control: point(5, 19))
                path.addQuadCurve(to: point(19, 12), control: point(19, 19))
                path.addLine(to: point(19, 10))
                path.move(to: point(12, 19))
                path.addLine(to: point(12, 23))
                path.move(to: point(8, 23))
                path.addLine(to: point(16, 23))
            case .expand:
                for (x, y, dx, dy): (Float, Float, Float, Float) in [(3, 3, 1, 1), (21, 3, -1, 1), (3, 21, 1, -1), (21, 21, -1, -1)] {
                    path.move(to: point(x + dx * 6, y))
                    path.addLine(to: point(x, y))
                    path.addLine(to: point(x, y + dy * 6))
                }
            case .collapse:
                for (x, y, dx, dy): (Float, Float, Float, Float) in [(9, 9, -1, -1), (15, 9, 1, -1), (9, 15, -1, 1), (15, 15, 1, 1)] {
                    path.move(to: point(x + dx * 6, y))
                    path.addLine(to: point(x, y))
                    path.addLine(to: point(x, y + dy * 6))
                }
            }
            return path
        }
    }
}
#endif
