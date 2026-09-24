@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

enum EditorGameWindowSize: String, CaseIterable {
    case project = "Project size"
    case hd = "1280 × 720"
    case fullHD = "1920 × 1080"
    case portrait = "720 × 1280"
    case custom = "Custom"

    func size(projectSize: Size, customWidth: String, customHeight: String) -> Size? {
        switch self {
        case .project: return projectSize
        case .hd: return Size(width: 1280, height: 720)
        case .fullHD: return Size(width: 1920, height: 1080)
        case .portrait: return Size(width: 720, height: 1280)
        case .custom:
            guard
                let width = Float(customWidth), width.isFinite, (320...4_096).contains(width),
                let height = Float(customHeight), height.isFinite, (240...4_096).contains(height)
            else { return nil }
            return Size(width: width, height: height)
        }
    }
}

@Observable
@MainActor
final class EditorGameWindowControls {
    let inspection = EditorPlayInspectionModel()
    let projectSize: Size
    var inputEnabled = true
    var selectedSize: EditorGameWindowSize = .project
    var customWidth: String
    var customHeight: String
    private(set) var windowSize: Size

    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private weak var inspector: EditorInspectorSidebarViewModel?
    @ObservationIgnored private var onEntitySelected: (() -> Void)?

    init(projectSize: Size) {
        self.projectSize = projectSize
        self.windowSize = projectSize
        self.customWidth = String(Int(projectSize.width))
        self.customHeight = String(Int(projectSize.height))
    }

    func attach(window: UIWindow, inspector: EditorInspectorSidebarViewModel, onEntitySelected: @escaping () -> Void) {
        self.window = window
        self.inspector = inspector
        self.onEntitySelected = onEntitySelected
        windowSize = Self.viewportSize(in: window)
        inspector.isInspectingPlayMode = true
        inspector.runtimeSelection = nil
    }

    func attach(world: World) {
        inspection.attach(world)
    }

    func refresh() {
        inspection.refresh()
        if let inspector, inspector.runtimeSelection != inspection.selection {
            inspector.runtimeSelection = inspection.selection
        }
        if let window, windowSize != Self.viewportSize(in: window) {
            windowSize = Self.viewportSize(in: window)
        }
    }

    func selectEntity(_ id: Entity.ID?) {
        inspection.select(id)
        inspector?.runtimeSelection = inspection.selection
        if id != nil { onEntitySelected?() }
    }

    func selectSize(_ size: EditorGameWindowSize) {
        selectedSize = size
        applySize()
    }

    func applySize() {
        guard let size = selectedSize.size(projectSize: projectSize, customWidth: customWidth, customHeight: customHeight), let window else { return }
        window.frame.size = Size(width: size.width, height: size.height + EditorGameWindowToolbar.height)
        windowSize = size
    }

    private static func viewportSize(in window: UIWindow) -> Size {
        Size(width: window.frame.width, height: max(1, window.frame.height - EditorGameWindowToolbar.height))
    }

    func finish() {
        inspector?.runtimeSelection = nil
        inspector?.isInspectingPlayMode = false
        inspection.reset()
        window = nil
        inspector = nil
        onEntitySelected = nil
    }
}

struct EditorGameWindowToolbar: View {
    static let height: Float = 40
    let controls: EditorGameWindowControls
    @Environment(\.theme) private var theme
    @Environment(\.viewProxy) private var viewProxy

    var body: some View {
        HStack(spacing: 9) {
            Button(controls.inputEnabled ? "Input" : "Inspect") {
                controls.inputEnabled.toggle()
                viewProxy.redraw()
            }
                .foregroundColor(controls.inputEnabled ? theme.editorColors.blue : theme.editorColors.text)
                .accessibilityIdentifier("AdaEditor.GameWindow.InputMode")
            entityPicker
            Spacer()
            Text("\(Int(controls.windowSize.width)) × \(Int(controls.windowSize.height))")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .accessibilityIdentifier("AdaEditor.GameWindow.Dimensions")
            EditorEnumField(
                cases: EditorGameWindowSize.allCases.map(\.rawValue),
                selection: Binding(
                    get: { controls.selectedSize.rawValue },
                    set: {
                        controls.selectSize(EditorGameWindowSize(rawValue: $0) ?? .project)
                        viewProxy.redraw()
                    }
                ),
                accessibilityID: "AdaEditor.GameWindow.Size"
            )
            .frame(width: 128)
            if controls.selectedSize == .custom {
                TextField("Width", text: Binding(get: { controls.customWidth }, set: { controls.customWidth = $0; controls.applySize(); viewProxy.redraw() }))
                    .frame(width: 58)
                    .accessibilityIdentifier("AdaEditor.GameWindow.Width")
                Text("×").foregroundColor(theme.editorColors.muted)
                TextField("Height", text: Binding(get: { controls.customHeight }, set: { controls.customHeight = $0; controls.applySize(); viewProxy.redraw() }))
                    .frame(width: 58)
                    .accessibilityIdentifier("AdaEditor.GameWindow.Height")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(theme.editorColors.surface)
        .accessibilityIdentifier("AdaEditor.GameWindow.Toolbar")
    }

    private var entityPicker: some View {
        HStack(spacing: 5) {
            Text(controls.inspection.selection?.name ?? "Select entity")
                .lineLimit(1)
            Text("\u{E5CF}").font(AdaEditorMaterialSymbolFont.font(size: 16))
        }
        .font(.system(size: 11))
        .foregroundColor(theme.editorColors.text)
        .padding(.horizontal, 8)
        .frame(width: 150, height: 28)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .contextMenu(opensOnPrimaryAction: true) {
            ContextMenuOption("None", isSelected: controls.inspection.selectedID == nil) {
                controls.selectEntity(nil)
                viewProxy.redraw()
            }
            ForEach(controls.inspection.items) { item in
                ContextMenuOption("\(item.name) (#\(item.id))", isSelected: controls.inspection.selectedID == item.id) {
                    controls.selectEntity(item.id)
                    viewProxy.redraw()
                }
            }
        }
        .accessibilityIdentifier("AdaEditor.GameWindow.EntityPicker")
    }
}
