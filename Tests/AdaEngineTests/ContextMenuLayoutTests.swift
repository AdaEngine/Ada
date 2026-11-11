@testable import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Testing

struct ContextMenuLayoutTests {
    @Test("context menu reserves a full single-line title column")
    func contextMenuTitleWidth() {
        let menuWidth = ContextMenuMetrics.width(longestTitleCharacterCount: "Copy Relative Path".count)
        let regularTitleWidth = ContextMenuMetrics.titleWidth(menuWidth: menuWidth, hasSubmenu: false)
        let submenuTitleWidth = ContextMenuMetrics.titleWidth(menuWidth: menuWidth, hasSubmenu: true)

        #expect(menuWidth == 184)
        #expect(regularTitleWidth == 164)
        #expect(submenuTitleWidth == 148)
        #expect(ContextMenuMetrics.titleWidth(menuWidth: ContextMenuMetrics.minimumWidth, hasSubmenu: false) == 164)
    }

    @MainActor
    @Test("keyboard selection starts at the current choice and reaches options below the viewport")
    func keyboardSelection() {
        let options = (0..<12).map {
            ContextMenuPresentation.Item(id: $0, title: "Option \($0)", isSelected: $0 == 8)
        }
        let selection = ContextMenuSelection(items: options)
        #expect(selection.index == 8)
        for _ in 0..<5 { #expect(selection.handle(.arrowDown) == .moved) }
        #expect(selection.handle(.enter) == .confirmed(11))
        #expect(selection.handle(.arrowUp) == .moved)
        #expect(selection.handle(.space) == .confirmed(10))
        #expect(selection.handle(.escape) == .ignored)
    }
}
