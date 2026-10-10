@_spi(AdaEngine) import AdaEngine

struct EditorTopToolbar: View {
    static let searchAccessibilityIdentifier = "AdaEditor.ProjectSearch"
    static let projectSwitcherAccessibilityIdentifier = "AdaEditor.ProjectSwitcher.Button"
    static let projectSwitcherIconAccessibilityIdentifier = "AdaEditor.ProjectSwitcher.Icon"

    let project: EditorProjectReference?
    let isProjectSwitcherPresented: Bool
    let isRunDestinationMenuPresented: Bool
    let viewModel: EditorToolbarViewModel
    let runDestination: EditorRunDestination
    let isRunEnabled: Bool
    let isStopEnabled: Bool
    let onToggleRunDestinationMenu: () -> Void
    let onToggleProjectSwitcher: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void
    var onDebug: (() -> Void)?
    var onOpenCloud: (() -> Void)?
    var interface: EditorInterfaceState?

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        EditorToolbarLayout(searchWidth: metrics.toolbarSearchWidth) {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: metrics.toolbarWindowControlClearance, height: 1)
                projectSwitcherButton
                #if os(macOS) || os(Windows) || os(Linux)
                if let interface {
                    EditorInterfaceModePicker(state: interface)
                }
                #endif
            }

            SearchBar(text: viewModel.searchTextBinding, prompt: viewModel.searchPrompt)
                .searchBarStyle(EditorToolbarSearchBarStyle(theme: theme))
                .accessibilityIdentifier(Self.searchAccessibilityIdentifier)

            HStack(spacing: 12) {
                EditorAICreditsBadge(compact: true, onOpen: onOpenCloud)
                EditorUpdateButton()
                runDestinationControls
                runStopControls
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var projectSwitcherButton: some View {
        Button(action: onToggleProjectSwitcher) {
            HStack(spacing: 6) {
                Text("\u{E2C7}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .accessibilityIdentifier(Self.projectSwitcherIconAccessibilityIdentifier)
                if metrics.toolbarProjectSwitcherWidth > 32 {
                    Text(project?.name ?? "Projects")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                Text(isProjectSwitcherPresented ? "\u{E5CE}" : "\u{E5CF}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
            }
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, metrics.toolbarProjectSwitcherWidth > 32 ? 8 : 0)
            .frame(width: metrics.toolbarProjectSwitcherWidth, height: 30, alignment: .leading)
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier(Self.projectSwitcherAccessibilityIdentifier)
    }

    private var runDestinationControls: some View {
        Button(action: onToggleRunDestinationMenu) {
            HStack(spacing: 5) {
                Text(runDestination.rawValue)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.blue)
                Text(isRunDestinationMenuPresented ? "\u{E5CE}" : "\u{E5CF}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
                    .foregroundColor(theme.editorColors.muted)
            }
            .padding(.horizontal, 8)
            .frame(width: metrics.toolbarRunDestinationWidth, height: 28)
        }
        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border.opacity(0.72), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.RunDestination.Button")
    }

    private var runStopControls: some View {
        HStack(spacing: 4) {
            if let onDebug {
                toolbarActionButton(title: "Debug", symbol: "\u{E868}", color: Color(red: 110 / 255, green: 205 / 255, blue: 126 / 255), action: onDebug)
                    .disabled(!isRunEnabled)
            }
            toolbarActionButton(title: "Run", symbol: "\u{E037}", color: Color(red: 110 / 255, green: 205 / 255, blue: 126 / 255), action: onRun)
                .disabled(!isRunEnabled)
                .opacity(isRunEnabled ? 1 : 0.45)
            toolbarActionButton(title: "Stop", symbol: "\u{E047}", color: Color(red: 232 / 255, green: 96 / 255, blue: 96 / 255), action: onStop)
                .disabled(!isStopEnabled)
                .opacity(isStopEnabled ? 1 : 0.45)
        }
        .frame(width: metrics.toolbarRunControlsWidth)
    }

    private func toolbarActionButton(title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 20))
                .frame(width: 30, height: 30)
        }
        .foregroundColor(color)
        .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
        .accessibilityIdentifier("AdaEditor.Toolbar.\(title)")
    }
}

struct EditorRunDestinationMenu: View {
    let selectedDestination: EditorRunDestination
    let onSelect: (EditorRunDestination) -> Void
    var androidTargets: [EditorAndroidTarget] = []
    var selectedAndroidTargetID: String?
    var androidStatus = ""
    var onSelectAndroid: ((EditorAndroidTarget) -> Void)?
    var onRefreshAndroid: (() -> Void)?
    var onAndroidSettings: (() -> Void)?

    private var menuWidth: Float { selectedDestination == .android ? 300 : EditorRunDestinationMenuLayout.width }

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(EditorRunDestination.availableCases, id: \.self) { destination in
                Button(
                    action: { onSelect(destination) },
                    label: {
                        HStack(spacing: 8) {
                            Text(destination.rawValue)
                                .font(.system(size: 12))
                            Spacer()
                            if selectedDestination == destination {
                                Text("\u{E5CA}")
                                    .font(AdaEditorMaterialSymbolFont.font(size: 15))
                            }
                        }
                        .foregroundColor(selectedDestination == destination ? theme.editorColors.blue : theme.editorColors.text)
                        .padding(.horizontal, 10)
                        .frame(width: menuWidth, height: EditorRunDestinationMenuLayout.rowHeight)
                    }
                )
                .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                .accessibilityIdentifier("AdaEditor.RunDestination.\(destination.rawValue)")
            }
            if selectedDestination == .android {
                Text(androidStatus).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    .lineLimit(3).padding(.horizontal, 10).frame(width: menuWidth)
                ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                ForEach(androidTargets) { target in
                    Button(action: { onSelectAndroid?(target) }) {
                        HStack(spacing: 8) {
                            Text((target.kind == .emulator ? "Emulator · " : "Device · ") + target.title)
                                .font(.system(size: 11)).lineLimit(2)
                            Spacer()
                            if selectedAndroidTargetID == target.id { Text("✓").font(.system(size: 12)) }
                        }
                        .foregroundColor(theme.editorColors.text).padding(.horizontal, 10)
                        .frame(width: menuWidth, height: 42)
                    }
                    .buttonStyle(EditorChromeHoverButtonStyle(theme: theme)).disabled(!target.isAvailable)
                    .accessibilityIdentifier("AdaEditor.Android.Target." + target.id)
                }
                }
                }.frame(width: menuWidth, height: min(Float(androidTargets.count) * 42, 210))
                HStack(spacing: 16) {
                    Button("Refresh") { onRefreshAndroid?() }.foregroundColor(theme.editorColors.blue)
                    Button("Android Settings…") { onAndroidSettings?() }.foregroundColor(theme.editorColors.blue)
                }
                .font(.system(size: 11)).padding(10)
            }
        }
        .padding(4)
        .frame(width: menuWidth + 8)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border, lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.RunDestination.Menu")
    }
}

enum EditorRunDestinationMenuLayout {
    static let width: Float = 108
    static let rowHeight: Float = 30
    static let trailingOffset: Float = 92

    static func topOffset(toolbarHeight: Float) -> Float {
        toolbarHeight - 2
    }
}

struct EditorProjectSearchResults: View {
    static let accessibilityIdentifier = "AdaEditor.ProjectSearchResults"

    let items: [EditorProjectSidebarViewModel.Item]
    let width: Float
    let onOpenSearchResult: (EditorProjectSidebarViewModel.Item) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: EditorProjectSearchResultsLayout.rowSpacing) {
            ForEach(items, id: \.id) { item in
                Button(action: { onOpenSearchResult(item) }) {
                    HStack(spacing: 10) {
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundColor(theme.editorColors.text)
                        Text(item.relativePath)
                            .font(.system(size: 10))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(width: width, height: EditorProjectSearchResultsLayout.rowHeight, alignment: .leading)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.SearchResult.\(item.relativePath)")
            }
        }
        .padding(EditorProjectSearchResultsLayout.padding)
        .frame(width: width + 8)
        .background(
            RoundedRectangleShape(cornerRadius: 8)
                .fill(theme.editorColors.surfaceElevated)
        )
        .overlay {
            RoundedRectangleShape(cornerRadius: 8)
                .stroke(theme.editorColors.border, lineWidth: 1)
        }
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

struct EditorProjectSearchResultsLayout {
    static let rowHeight: Float = 30
    static let rowSpacing: Float = 2
    static let padding: Float = 4

    static func height(itemCount: Int) -> Float {
        let count = Swift.max(0, itemCount)
        let spacingCount = Swift.max(0, count - 1)
        return Float(count) * rowHeight + Float(spacingCount) * rowSpacing + padding * 2
    }

    static func topOffset(toolbarHeight: Float) -> Float {
        toolbarHeight - padding
    }
}

private struct EditorToolbarSearchBarStyle: SearchBarStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\u{E8B6}")
                .font(AdaEditorMaterialSymbolFont.font(size: 17))
                .foregroundColor(theme.editorColors.text.opacity(0.88))
                .frame(width: 18, height: 18)

            configuration.label
                .foregroundColor(theme.editorColors.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !configuration.isEmpty {
                Button(action: configuration.clear) {
                    Text("\u{E5CD}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                        .foregroundColor(theme.editorColors.text.opacity(0.86))
                }
                .accessibilityIdentifier("AdaUI.SearchBar.clearButton")
                .buttonStyle(EditorToolbarSearchBarClearButtonStyle(theme: theme))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.editorToolbarSearch(theme: theme), in: CapsuleShape())
    }
}

private struct EditorToolbarSearchBarClearButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 24, height: 24)
            .background {
                CircleShape().fill(configuration.state.isHighlighted ? theme.editorColors.surface.opacity(0.72) : .clear)
            }
            .opacity(configuration.state.isHighlighted ? 0.72 : 1.0)
    }
}

extension Glass {
    static func editorToolbarSearch(theme: Theme) -> Glass {
        var glass = Self.regular
        glass.blurRadius = 18
        glass.glassTintStrength = 0.52
        glass.edgeShadowStrength = 0
        glass.tintColor = theme.editorColors.surface.opacity(0.46)
        return glass
    }
}
