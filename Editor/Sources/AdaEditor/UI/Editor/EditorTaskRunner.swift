@_spi(AdaEngine) import AdaEngine

struct EditorTaskRunnerGroup: Identifiable {
    struct Item: Identifiable {
        let id: String
        let title: String
    }
    let id: String
    let title: String
    let tasks: [Item]
}

struct EditorTaskRunner: View {
    let groups: [EditorTaskRunnerGroup]
    let isEnabled: Bool
    let onRun: (String) -> Void
    @State private var collapsed: Set<String> = ["maintenance"]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in groupRow(group) }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupRow(_ group: EditorTaskRunnerGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if !collapsed.insert(group.id).inserted {
                    collapsed.remove(group.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(collapsed.contains(group.id) ? "\u{E5CC}" : "\u{E5CF}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    Text(group.title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(theme.editorColors.muted)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Tasks.Group.\(group.id)")
            if !collapsed.contains(group.id) {
                if group.tasks.isEmpty {
                    Text("No runnable products")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted).padding(.leading, 24)
                }
                ForEach(group.tasks) { task in taskRow(task) }
            }
        }
    }

    private func taskRow(_ task: EditorTaskRunnerGroup.Item) -> some View {
        Button {
            onRun(task.id)
        } label: {
            HStack(spacing: 8) {
                Text("\u{E037}")
                    .font(AdaEditorMaterialSymbolFont.font(size: 16))
                    .foregroundColor(Color.fromHex(0x35D6B1))
                    .frame(width: 20, height: 20)
                    .overlay { CircleShape().stroke(Color.fromHex(0x35D6B1), lineWidth: 1) }
                Text(task.title).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 20)
            .padding(.trailing, 6)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
            .foregroundColor(theme.editorColors.text)
        }
        .buttonStyle(EditorTaskRowStyle(theme: theme))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier("AdaEditor.Tasks.Run.\(task.id)")
    }
}

private struct EditorTaskRowStyle: ButtonStyle {
    let theme: Theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(RoundedRectangleShape(cornerRadius: 5).fill(configuration.isHighlighted ? theme.editorColors.surface : .clear))
    }
}

extension EditorTaskRunnerGroup {
    static func swiftPackage(products: [String]) -> [Self] {
        [
            .init(id: "build", title: "Build & Test", tasks: [.init(id: "build", title: "Build All"), .init(id: "test", title: "Run Tests")]),
            .init(id: "run", title: "Run", tasks: [.init(id: "runSelected", title: "Run Selected")]),
            .init(id: "products", title: "Run Products", tasks: products.map { .init(id: "product:\($0)", title: $0) }),
            .init(id: "dependencies", title: "Dependencies", tasks: [.init(id: "resolve", title: "Resolve Dependencies"), .init(id: "update", title: "Update Dependencies")]),
            .init(id: "maintenance", title: "Maintenance", tasks: [.init(id: "clean", title: "Clean Build Artifacts"), .init(id: "reset", title: "Reset Package Cache")]),
        ]
    }
}
