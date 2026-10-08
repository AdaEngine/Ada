import Testing
@testable import AdaPlatform
@testable import AdaUI

@MainActor
struct MenuBarModifierTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func menuBarModifierInsertsMenusWhenContainerBuildsMenu() {
        let fileMenu = UIMenu(title: "File")
        fileMenu.add(MenuItem(title: "Open"))
        let editMenu = UIMenu(title: "Edit")
        editMenu.add(MenuItem(title: "Copy"))

        let tester = ViewTester {
            Text("Root")
                .menuBar(fileMenu, editMenu)
        }
        let builder = RecordingMenuBuilder()

        tester.containerView.buildMenu(with: builder)

        #expect(builder.insertedMenus.map(\.title) == ["File", "Edit"])
    }
}

@MainActor
private final class RecordingMenuBuilder: UIMenuBuilder {
    var insertedMenus: [UIMenu] = []
    var removedMenus: [UIMenu.ID] = []
    var didRequestUpdate = false

    func insert(_ menu: UIMenu) {
        insertedMenus.append(menu)
    }

    func remove(_ menu: UIMenu.ID) {
        removedMenus.append(menu)
    }

    func setNeedsUpdate() {
        didRequestUpdate = true
    }

    func updateIfNeeded() {}
}
