import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorMenuBarTests {
    @Test
    func menuBarContainsEditorWorkflowMenus() {
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let menus = EditorMenuBar.makeMenus()

        #if os(Windows) || os(Linux)
        let applicationTitle = "Studio"
        #else
        let applicationTitle = "System"
        #endif
        #expect(menus.map(\.title) == [applicationTitle, "File", "Edit", "View", "Project", "Build", "Code", "Window", "Help"])
        #expect(menus.allSatisfy { !$0.items.isEmpty })
        #expect(menus.flatMap(\.items).filter { !$0.isSeparator }.allSatisfy { $0.isEnabled })
        #expect(menus.first?.placement == .application)
        #if os(Windows) || os(Linux)
        #expect(menus.first?.image != nil)
        #endif
    }

    @Test
    func workflowMenusExposeExpectedActionsAndShortcuts() throws {
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let menus = EditorMenuBar.makeMenus()
        let edit = try #require(menus.first { $0.title == "Edit" })
        #expect(edit.items.first { $0.title == "Undo" }?.keyEquivalent == .z)
        #expect(edit.items.first { $0.title == "Redo" }?.keyEquivalentModifierMask == [.command, .alt])
        let file = try #require(menus.first { $0.title == "File" })
        let build = try #require(menus.first { $0.title == "Build" })
        let code = try #require(menus.first { $0.title == "Code" })
        let system = try #require(menus.first { $0.placement == .application })

        #expect(file.items.map(\.title).contains("New File"))
        #expect(file.items.map(\.title).contains("Open Project..."))
        #expect(file.items.map(\.title).contains("Save All"))
        #expect(build.items.map(\.title).contains("Build Project"))
        #expect(build.items.map(\.title).contains("Run Tests"))
        #expect(code.items.map(\.title).contains("Show Preview"))
        #expect(code.items.map(\.title).contains("Rebuild Preview"))
        #expect(edit.items.first { $0.title == "Find in File" }?.keyEquivalent == .f)
        #expect(edit.items.first { $0.title == "Find in Project" }?.keyEquivalentModifierMask == [.command, .shift])
        let systemTitles = system.items.filter { !$0.isSeparator }.map(\.title)
        let expectedPrefix = EditorDistribution.current == .standalone ? ["Settings...", "Check for Updates…"] : ["Settings..."]
        #expect(systemTitles.starts(with: expectedPrefix))
        #expect(systemTitles.contains("Movie Maker"))
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
        #expect(file.items.first { $0.title == "Close Editor Tab" }?.keyEquivalentModifierMask == .command)
        #expect(file.items.first { $0.title == "Close Window" }?.keyEquivalentModifierMask == [.command, .shift])
        #expect(code.items.first { $0.title == "Close Editor Tab" } == nil)
        #if os(Windows)
        #expect(code.items.first { $0.title == "Increase Font Size" }?.keyEquivalent == .equals)
        #endif
        #expect(build.items.first { $0.title == "Build Project" }?.keyEquivalent == .b)
    }
}
