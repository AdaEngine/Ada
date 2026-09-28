@_spi(AdaEngine) import AdaEngine

struct EditorSceneViewportControls: View {
    let activeTool: EditorSceneViewportTool
    let displayMode: EditorSceneViewportDisplayMode
    let isPlaying: Bool
    let size: Size
    let onPlay: () -> Void
    let onSelectDisplayMode: (EditorSceneViewportDisplayMode) -> Void
    let onSelectTool: (EditorSceneViewportTool) -> Void
    let onStop: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
            ScrollView(.horizontal) {
                controlsPill
                    .padding(.horizontal, 8)
            }
            .frame(width: size.width, height: 42)
            .padding(.top, displayMode == .twoD ? 38 : 24)
            #else
            controlsPill
                .padding(.leading, 24)
                .padding(.top, displayMode == .twoD ? 38 : 24)
            #endif
            Spacer()
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var controlsPill: some View {
        HStack(spacing: 5) {
            if isPlaying {
                Text("Playing")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.editorColors.purple)
                    .padding(.horizontal, 7)
                pillButton(
                    "Stop",
                    symbol: "\u{E047}",
                    active: true,
                    color: theme.editorColors.purple,
                    action: onStop
                )
            } else {
                ForEach(EditorSceneViewportTool.allCases, id: \.rawValue) { tool in
                    pillButton(tool.rawValue, symbol: tool.symbol, active: activeTool == tool) {
                        onSelectTool(tool)
                    }
                }
                divider
                modeButton(.twoD)
                modeButton(.threeD)
                divider
                pillButton(
                    "Play",
                    symbol: "\u{E037}",
                    active: false,
                    color: Color(red: 110 / 255, green: 205 / 255, blue: 126 / 255),
                    action: onPlay
                )
            }
        }
        .padding(5)
        .background(CapsuleShape().fill(theme.editorColors.surface))
        .overlay {
            CapsuleShape().stroke(theme.editorColors.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 5, shape: .capsule)
        .accessibilityIdentifier("AdaEditor.SceneViewport.Controls")
    }

    private var divider: some View {
        RectangleShape()
            .fill(theme.editorColors.border.opacity(0.8))
            .frame(width: 1, height: 18)
    }

    private func modeButton(_ mode: EditorSceneViewportDisplayMode) -> some View {
        pillButton(mode.rawValue, symbol: "", active: displayMode == mode) {
            onSelectDisplayMode(mode)
        }
    }

    private func pillButton(
        _ title: String,
        symbol: String,
        active: Bool,
        color: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            pillLabel(title, symbol: symbol, active: active, color: color)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.SceneViewport.Control.\(title)")
    }

    private func pillLabel(_ title: String, symbol: String, active: Bool, color: Color?) -> some View {
        HStack(spacing: 4) {
            #if !os(iOS)
            if !symbol.isEmpty {
                Text(symbol)
                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
            }
            #endif
            Text(title)
                .font(.system(size: 10))
        }
        .foregroundColor(color ?? (active ? theme.editorColors.text : theme.editorColors.muted))
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(CapsuleShape().fill(active ? theme.editorColors.blue.opacity(0.22) : Color.clear))
    }
}

extension EditorSceneViewportTool {
    var symbol: String {
        switch self {
        case .select: "\u{E8B6}"
        case .translate: "\u{E89F}"
        case .scale: "\u{E8FF}"
        case .rotate: "\u{E863}"
        }
    }
}
