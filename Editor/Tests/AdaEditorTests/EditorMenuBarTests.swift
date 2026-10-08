import Testing

@testable import AdaEditor

@MainActor
struct EditorMenuBarTests {
    @Test
    func menuBarContainsEditorWorkflowMenus() {
        let menus = EditorMenuBar.makeMenus()

        #expect(menus.map(\.title) == ["System", "File", "Edit", "View", "Project", "Build", "Code", "Window", "Help"])
        #expect(menus.allSatisfy { !$0.items.isEmpty })
        #expect(menus.flatMap(\.items).filter { !$0.isSeparator }.allSatisfy { $0.isEnabled })
        #expect(menus.first?.placement == .application)
    }

    @Test
    func workflowMenusExposeExpectedActionsAndShortcuts() throws {
        let menus = EditorMenuBar.makeMenus()
        let edit = try #require(menus.first { $0.title == "Edit" })
        #expect(edit.items.first { $0.title == "Undo" }?.keyEquivalent == .z)
        #expect(edit.items.first { $0.title == "Redo" }?.keyEquivalentModifierMask == [.main, .alt])
        let file = try #require(menus.first { $0.title == "File" })
        let build = try #require(menus.first { $0.title == "Build" })
        let code = try #require(menus.first { $0.title == "Code" })
        let system = try #require(menus.first { $0.title == "System" })

        #expect(file.items.map(\.title).contains("New File"))
        #expect(file.items.map(\.title).contains("Open Project..."))
        #expect(file.items.map(\.title).contains("Save All"))
        #expect(build.items.map(\.title).contains("Build Project"))
        #expect(build.items.map(\.title).contains("Run Tests"))
        #expect(code.items.map(\.title).contains("Show Preview"))
        #expect(code.items.map(\.title).contains("Rebuild Preview"))
        #expect(edit.items.first { $0.title == "Find in File" }?.keyEquivalent == .f)
        #expect(edit.items.first { $0.title == "Find in Project" }?.keyEquivalentModifierMask == [.main, .shift])
        let systemTitles = system.items.filter { !$0.isSeparator }.map(\.title)
        let expectedPrefix = EditorDistribution.current == .standalone ? ["Settings...", "Check for Updates…"] : ["Settings..."]
        #expect(systemTitles.starts(with: expectedPrefix))
        #expect(Array(systemTitles.suffix(5)) == [
            "Disable Debug Overlay",
            "Debug Overlay: Redraw",
            "Debug Overlay: Layout Bounds",
            "Debug Overlay: Hit Test Target",
            "Debug Overlay: Focused Node",
        ])
        #expect(system.items.first?.keyEquivalent == .comma)
        #expect(file.items.first { $0.title == "Save" }?.keyEquivalent == .s)
        #expect(file.items.first { $0.title == "Close Editor Tab" }?.keyEquivalent == .w)
        #expect(file.items.first { $0.title == "Close Editor Tab" }?.keyEquivalentModifierMask == .main)
        #expect(file.items.first { $0.title == "Close Window" }?.keyEquivalentModifierMask == [.main, .shift])
        #expect(code.items.first { $0.title == "Close Editor Tab" } == nil)
        #expect(build.items.first { $0.title == "Build Project" }?.keyEquivalent == .b)
    }
}
