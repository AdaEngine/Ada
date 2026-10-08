import AdaEngine

public enum InventoryUIExports: UIExportProvider {
    public static var views: [UINativeViewDescriptor] {
        [.init(signature: .init(id: "Game.Badge", name: "Item Badge", parameters: [
            .init("title", type: .string, defaultValue: .string("Item"))
        ])) { inputs in
            AnyView(ItemBadge(title: inputs.string("title")))
        }]
    }
}

private struct ItemBadge: View {
    let title: String
    var body: some View {
        Text(title).fontSize(18).foregroundColor(.white)
            .padding(8).background(Color.blue.opacity(0.3))
    }
}

/// Use from an App/scene after installing the normal rendering, assets and UI plugins.
@MainActor
public func makeInventory(resourceRoot: URL, onSelect: @escaping () -> Void) throws -> UIComponent {
    let catalog = try UICatalog.standard.adding(views: InventoryUIExports.views)
    let data = UIBindingContext()
    data.on("selectItem") { _ in onSelect() }
    return try UIComponent(ui: "Inventory.ui", context: data, resourceRoot: resourceRoot, catalog: catalog)
}
