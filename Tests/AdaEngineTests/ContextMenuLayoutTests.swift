@testable import AdaEngine
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
}
