@_spi(AdaEngine) import AdaEngine
import Foundation

enum MobileEditorHomeTab: String, Hashable {
    case studio
    case community
}

struct MobileEditorHomeTabs<Studio: View>: View {
    @Environment(\.theme) private var theme
    @State private var selection: MobileEditorHomeTab
    let studio: Studio
    var showsTabBar = true
    let server: URL?

    init(studio: Studio, showsTabBar: Bool = true, server: URL? = nil) {
        self.studio = studio
        self.server = server
        self.showsTabBar = showsTabBar
        let saved = UserDefaults.standard.string(forKey: "AdaEditor.mobile.homeTab")
        self._selection = State(wrappedValue: saved.flatMap(MobileEditorHomeTab.init(rawValue:)) ?? .studio)
    }

    private var resolvedServer: URL {
        if let server { return server }
        let address = EditorCloudConfiguration.server(
            environment: ProcessInfo.processInfo.environment["ADA_CLOUD_API_URL"],
            saved: UserDefaults.standard.string(forKey: "AdaEditor.cloud.server"),
            bundled: Bundle.main.object(forInfoDictionaryKey: "AdaCloudAPIURL") as? String
        )
        return URL(string: address) ?? URL(fileURLWithPath: "/")
    }

    var body: some View {
        TabView(selection: Binding(
            get: { showsTabBar ? selection : .studio },
            set: { selection = $0 }
        )) {
            Tab("Studio", value: MobileEditorHomeTab.studio) {
                studio
            }
            Tab("Community", value: MobileEditorHomeTab.community) {
                EditorCommunityView(client: EditorCommunityClient(server: resolvedServer))
                    .id(resolvedServer)
            }
        }
        .tabViewPosition(.bottom)
        .tabViewStyle(MobileEditorHomeTabStyle(
            showsTabBar: showsTabBar,
            style: LiquidGlassTabBarStyle(
                backgroundColor: theme.editorColors.surface.opacity(0.12),
                borderColor: theme.editorColors.border,
                selectedColor: theme.editorColors.text,
                unselectedColor: theme.editorColors.muted,
                symbols: ["Studio": "\u{E86F}", "Community": "\u{E80B}"],
                symbolFont: AdaEditorMaterialSymbolFont.font(size: 22),
                labelFont: .system(size: 11)
            )
        ))
        .background(theme.editorColors.background.ignoresSafeArea())
        .onChange(of: selection) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: "AdaEditor.mobile.homeTab")
        }
    }
}

/// Keep cached tab content and its navigation alive while workspace controls take over.
private struct MobileEditorHomeTabStyle: TabViewStyle {
    let showsTabBar: Bool
    let style: LiquidGlassTabBarStyle

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if showsTabBar {
            style.makeBody(configuration: configuration)
        } else {
            configuration.content
        }
    }
}
