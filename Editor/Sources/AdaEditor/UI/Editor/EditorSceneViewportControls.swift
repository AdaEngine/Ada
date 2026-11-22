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
    var showsEditingTools = true
    var showsPlayback = true
    var inline = false

    @Environment(\.theme) private var theme
    private var compact: Bool { AdaEngineStyleLayoutSpec.usesCompactWorkspace }

    @ViewBuilder
    var body: some View {
        if inline {
            controls
        } else {
            overlayControls
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(iOS)
            ScrollView(.horizontal) {
                controlsPill
                    .padding(.horizontal, 8)
            }
            .frame(width: size.width, height: 42)
            .padding(.top, displayMode == .twoD ? 38 : 24)
            #else
            if compact && size.width < 230 {
                ScrollView(.horizontal, showsIndicators: true) {
                    controlsPill.fixedSize(horizontal: true, vertical: false)
                }
                .frame(width: size.width, height: 34)
                .padding(.top, displayMode == .twoD ? 38 : 6)
            } else {
                controlsPill
                    .padding(.leading, compact ? 6 : 24)
                    .padding(.top, displayMode == .twoD ? 38 : compact ? 6 : 24)
            }
            #endif
            Spacer()
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var controlsPill: some View {
        controls
            .padding(compact ? 2 : 5)
            .background {
                if compact {
                    RoundedRectangleShape(cornerRadius: AdaEngineStyleLayoutSpec.workspaceControlRadius)
                        .fill(theme.editorColors.surface)
                } else {
                    CapsuleShape().fill(theme.editorColors.surface)
                        .shadow(color: .black.opacity(0.38), radius: 9, x: 0, y: 5, shape: .capsule)
                }
            }
            .overlay {
                if compact {
                    adaEditorPanelBorder(theme: theme, cornerRadius: AdaEngineStyleLayoutSpec.workspaceControlRadius)
                } else {
                    CapsuleShape().stroke(theme.editorColors.border.opacity(0.9), lineWidth: 1)
                }
            }
    }

    private var controls: some View {
        HStack(spacing: compact ? 3 : 5) {
            if isPlaying {
                Text(L10n.text("Playing"))
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
                if showsEditingTools {
                    ForEach(EditorSceneViewportTool.allCases, id: \.rawValue) { tool in
                        pillButton(tool.rawValue, symbol: tool.symbol, active: activeTool == tool) {
                            onSelectTool(tool)
                        }
                    }
                    divider
                }
                modeButton(.twoD)
                modeButton(.threeD)
                if showsPlayback {
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
        }
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

    @ViewBuilder
    private func pillButton(
        _ title: String,
        symbol: String,
        active: Bool,
        color: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let identifier = "AdaEditor.SceneViewport.Control.\(title)"
        if compact && !symbol.isEmpty {
            EditorSceneToolbarButton(
                title: title,
                symbol: symbol,
                identifier: identifier,
                isSelected: active,
                compact: true,
                tint: color ?? (active ? theme.editorColors.text : theme.editorColors.muted),
                action: action
            )
        } else {
            Button(action: action) {
                pillLabel(title, symbol: symbol, active: active, color: color)
            }
            .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
            .accessibilityIdentifier(identifier)
        }
    }

    private func pillLabel(_ title: String, symbol: String, active: Bool, color: Color?) -> some View {
        HStack(spacing: 4) {
            #if !os(iOS)
            if !symbol.isEmpty {
                Text(symbol)
                    .font(AdaEditorMaterialSymbolFont.font(size: compact ? AdaEngineStyleLayoutSpec.workspaceIconSize : 15))
            }
            #endif
            Text(L10n.tr(title))
                .font(.system(size: 10))
        }
        .foregroundColor(color ?? (active ? theme.editorColors.text : theme.editorColors.muted))
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background {
            if compact {
                RoundedRectangleShape(cornerRadius: AdaEngineStyleLayoutSpec.workspaceControlRadius)
                    .fill(active ? theme.editorColors.blue.opacity(0.22) : .clear)
            } else {
                CapsuleShape().fill(active ? theme.editorColors.blue.opacity(0.22) : .clear)
            }
        }
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
