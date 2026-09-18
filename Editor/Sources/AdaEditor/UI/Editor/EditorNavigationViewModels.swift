@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

@Observable
@MainActor
final class EditorToolbarViewModel {
    var searchText: String
    var sceneName: String
    var searchableItems: [EditorProjectSidebarViewModel.Item]
    var searchScopeRelativePath: String?

    init(
        searchText: String = "",
        sceneName: String = "main_scene",
        searchableItems: [EditorProjectSidebarViewModel.Item] = [],
        searchScopeRelativePath: String? = nil
    ) {
        self.searchText = searchText
        self.sceneName = sceneName
        self.searchableItems = searchableItems
        self.searchScopeRelativePath = searchScopeRelativePath
    }

    var searchTextBinding: Binding<String> {
        Binding(get: { self.searchText }, set: { self.searchText = $0 })
    }

    var searchPrompt: String {
        guard let searchScopeRelativePath else {
            return "Search Project Files"
        }
        return "Search in \(searchScopeRelativePath)"
    }

    var searchResults: [EditorProjectSidebarViewModel.Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }

        let scopedItems = searchableItems.filter { item in
            guard !item.isFolder else {
                return false
            }
            guard let searchScopeRelativePath else {
                return true
            }
            return item.relativePath.hasPrefix("\(searchScopeRelativePath)/")
        }

        return Array(
            scopedItems
            .filter { item in
                item.title.localizedCaseInsensitiveContains(query)
                    || item.relativePath.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                let lhsStartsWithQuery = lhs.title.lowercased().hasPrefix(query.lowercased())
                let rhsStartsWithQuery = rhs.title.lowercased().hasPrefix(query.lowercased())
                if lhsStartsWithQuery != rhsStartsWithQuery {
                    return lhsStartsWithQuery
                }
                return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
            .prefix(12)
        )
    }

    func search(in item: EditorProjectSidebarViewModel.Item?) {
        searchScopeRelativePath = item?.relativePath
        searchText = ""
    }

    func clearSearch() {
        searchText = ""
        searchScopeRelativePath = nil
    }
}

@Observable
@MainActor
final class EditorToolStripViewModel {
    var activeLeftTopTool: String
    var activeLeftBottomTool: String
    var activeRightTool: String
    var leftTopTools: [EditorToolStripItem]
    var leftBottomTools: [EditorToolStripItem]
    var rightTools: [EditorToolStripItem]

    init(
        activeLeftTopTool: String = "fileTree",
        activeLeftBottomTool: String = "logs",
        activeRightTool: String = "agentChat",
        leftTopTools: [EditorToolStripItem] = AdaEngineStyleContent.leftTopSidebarTools,
        leftBottomTools: [EditorToolStripItem] = AdaEngineStyleContent.leftBottomSidebarTools,
        rightTools: [EditorToolStripItem] = AdaEngineStyleContent.rightSidebarTools
    ) {
        self.activeLeftTopTool = activeLeftTopTool
        self.activeLeftBottomTool = activeLeftBottomTool
        self.activeRightTool = activeRightTool
        self.leftTopTools = leftTopTools
        self.leftBottomTools = leftBottomTools
        self.rightTools = rightTools
    }

    func selectLeftTopTool(_ item: EditorToolStripItem) {
        activeLeftTopTool = item.identifier
    }

    func selectLeftBottomTool(_ item: EditorToolStripItem) {
        activeLeftBottomTool = item.identifier
    }

    func selectRightTool(_ item: EditorToolStripItem) {
        activeRightTool = item.identifier
    }
}

@Observable
@MainActor
final class EditorProjectSidebarViewModel {
    struct SourceRootTarget: Equatable {
        var relativePath: String
        var title: String
    }

    enum DisplayMode: String, CaseIterable {
        case targets
        case files

        var title: String {
            switch self {
            case .targets:
                "Targets"
            case .files:
                "Files"
            }
        }
    }

    struct Item: Equatable {
        var id: String
        var disclosure: String
        var icon: String
        var title: String
        var relativePath: String
        var level: Int
        var isActive: Bool
        var isFolder: Bool
        var isSymbolicLink: Bool = false
        var kind: EditorProjectFileKind
        var assetRoot: String?
    }

    var items: [Item]
    var collapsedFolderIDs: Set<String>
    var displayMode: DisplayMode
    var isDisplayModeMenuPresented: Bool
    let sourceRootTarget: SourceRootTarget?

    var visibleItems: [Item] {
        let displayedItems = displayedItems
        let displayedFolderIDs = Set(displayedItems.lazy.filter(\.isFolder).map(\.id))
        return displayedItems.filter { !isHiddenByCollapsedFolder($0, displayedFolderIDs: displayedFolderIDs) }
    }

    var selectedItem: Item? {
        items.first(where: \.isActive)
    }

    init(
        items: [Item] = [
            Item(id: "src", disclosure: "", icon: "▱", title: "src", relativePath: "src", level: 0, isActive: false, isFolder: true, kind: .folder),
            Item(
                id: "src/EngineLoop.ada",
                disclosure: "",
                icon: "▱",
                title: "EngineLoop.ada",
                relativePath: "src/EngineLoop.ada",
                level: 1,
                isActive: true,
                isFolder: false,
                kind: .text(.ada)
            ),
            Item(
                id: "src/Renderer.ada",
                disclosure: "",
                icon: "▱",
                title: "Renderer.ada",
                relativePath: "src/Renderer.ada",
                level: 1,
                isActive: false,
                isFolder: false,
                kind: .text(.ada)
            ),
            Item(
                id: "Assets/Scenes/Main.ascn",
                disclosure: "",
                icon: "▱",
                title: "Main.ascn",
                relativePath: "Assets/Scenes/Main.ascn",
                level: 1,
                isActive: false,
                isFolder: false,
                kind: .scene
            ),
        ],
        collapsedFolderIDs: Set<String> = [],
        displayMode: DisplayMode = .targets,
        isDisplayModeMenuPresented: Bool = false,
        sourceRootTarget: SourceRootTarget? = nil
    ) {
        self.items = items
        self.collapsedFolderIDs = collapsedFolderIDs
        self.displayMode = displayMode
        self.isDisplayModeMenuPresented = isDisplayModeMenuPresented
        self.sourceRootTarget = sourceRootTarget
    }

    private var displayedItems: [Item] {
        switch displayMode {
        case .files:
            items
        case .targets:
            targetItems
        }
    }

    private var targetItems: [Item] {
        var targetRoots = items.filter { item in
            item.assetRoot == item.relativePath || isSourceTarget(item)
        }
        if let sourceRootTarget,
            var sourceRoot = items.first(where: { $0.isFolder && $0.relativePath == sourceRootTarget.relativePath }),
            !targetRoots.contains(where: { $0.id == sourceRoot.id }) {
            sourceRoot.title = sourceRootTarget.title
            targetRoots.append(sourceRoot)
            targetRoots.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }

        return targetRoots.flatMap { root in
            items.compactMap { item in
                guard item.relativePath == root.relativePath || item.relativePath.hasPrefix("\(root.relativePath)/") else {
                    return nil
                }

                var targetItem = item
                targetItem.level -= root.level
                if targetItem.id == root.id {
                    targetItem.title = root.title
                }
                return targetItem
            }
        }
    }

    func select(_ selectedItem: Item) {
        for index in items.indices {
            items[index].isActive = items[index].id == selectedItem.id
        }
    }

    func selectDisplayMode(_ displayMode: DisplayMode) {
        self.displayMode = displayMode
        isDisplayModeMenuPresented = false
    }

    func toggleDisplayModeMenu() {
        isDisplayModeMenuPresented.toggle()
    }

    func toggleFolder(_ item: Item) {
        guard item.isFolder else {
            return
        }

        if collapsedFolderIDs.contains(item.id) {
            collapsedFolderIDs.remove(item.id)
        } else {
            collapsedFolderIDs.insert(item.id)
        }
    }

    func isCollapsed(_ item: Item) -> Bool {
        item.isFolder && collapsedFolderIDs.contains(item.id)
    }

    func expandAll() {
        collapsedFolderIDs.removeAll()
    }

    func collapseAll() {
        collapsedFolderIDs = Set(items.lazy.filter(\.isFolder).map(\.id))
    }

    private func isHiddenByCollapsedFolder(_ item: Item, displayedFolderIDs: Set<String>) -> Bool {
        collapsedFolderIDs.contains { collapsedFolderID in
            guard
                displayedFolderIDs.contains(collapsedFolderID),
                item.id != collapsedFolderID,
                let collapsedFolder = items.first(where: { $0.id == collapsedFolderID })
            else {
                return false
            }

            return item.relativePath.hasPrefix("\(collapsedFolder.relativePath)/")
        }
    }

    private func isSourceTarget(_ item: Item) -> Bool {
        item.isFolder && item.level == 1 && item.relativePath.hasPrefix("Sources/")
    }
}
