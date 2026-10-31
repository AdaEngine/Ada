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

    // Tree topology and row selection have separate observation lifetimes.
    // A tab change updates two rows without rebuilding the tree's disclosure
    // presentation and every mounted context menu.
    @ObservationIgnored private var storedItems: [Item]
    @ObservationIgnored private var selectedItemID: String?
    @ObservationIgnored private var rowSelections: [String: EditorProjectTreeRowSelection] = [:]
    private var itemsRevision: UInt64 = 0
    private var selectionRevision: UInt64 = 0
    var items: [Item] {
        get {
            _ = itemsRevision
            return storedItems
        }
        set {
            storedItems = newValue
            synchronizeRowSelections()
            let validIDs = Set(newValue.map(\.id))
            rowSelections = rowSelections.filter { validIDs.contains($0.key) }
            itemsRevision &+= 1
        }
    }
    var collapsedFolderIDs: Set<String> {
        didSet { persistExpandedFolders() }
    }
    var displayMode: DisplayMode
    var isDisplayModeMenuPresented: Bool
    var revealedItemID: String?
    var revealRevision: UInt64 = 0
    let sourceRootTarget: SourceRootTarget?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let expansionPreferenceKey: String?

    var hasExpandedFolders: Bool {
        displayedItems.contains { $0.isFolder && !collapsedFolderIDs.contains($0.id) }
    }

    var hasFolders: Bool { displayedItems.contains(where: \.isFolder) }

    var visibleItems: [Item] {
        let span = AdaTrace.startSpan("AdaEditor.ProjectTree.visibleItems")
        defer { span.end() }
        let displayedItems = displayedItems
        let collapsedIDs = collapsedFolderIDs
        let collapsedPaths = Set(displayedItems.lazy.filter { $0.isFolder && collapsedIDs.contains($0.id) }.map(\.relativePath))
        return displayedItems.filter { !Self.isHiddenByCollapsedFolder($0, collapsedPaths: collapsedPaths) }
    }

    var selectedItem: Item? {
        _ = itemsRevision
        _ = selectionRevision
        return storedItems.first(where: \.isActive)
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
        collapsedFolderIDs: Set<String>? = nil,
        displayMode: DisplayMode = .targets,
        isDisplayModeMenuPresented: Bool = false,
        sourceRootTarget: SourceRootTarget? = nil,
        projectPath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        let preferenceKey = projectPath.map { "AdaEditor.ProjectTree.ExpandedFolders." + URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.expansionPreferenceKey = preferenceKey
        let expandedPaths = Set(preferenceKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        self.storedItems = items
        self.selectedItemID = items.first(where: \.isActive)?.id
        self.collapsedFolderIDs = collapsedFolderIDs
            ?? Set(items.lazy.filter { $0.isFolder && !expandedPaths.contains($0.relativePath) }.map(\.id))
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

        // A source/resource root already contains its descendants. Listing those
        // folders as separate targets duplicates IDs and removes their indentation.
        let roots = targetRoots.filter { candidate in
            !targetRoots.contains { other in
                candidate.id != other.id && candidate.relativePath.hasPrefix(other.relativePath + "/")
            }
        }
        return roots.flatMap { root in
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
        var updated = storedItems
        var changed = false
        for index in updated.indices {
            let active = updated[index].id == selectedItem.id
            if updated[index].isActive != active {
                updated[index].isActive = active
                changed = true
            }
        }
        guard changed else { return }
        storedItems = updated
        synchronizeRowSelections()
    }

    func rowSelection(for item: Item) -> EditorProjectTreeRowSelection {
        if let selection = rowSelections[item.id] { return selection }
        let selection = EditorProjectTreeRowSelection(isActive: storedItems.first { $0.id == item.id }?.isActive ?? false)
        rowSelections[item.id] = selection
        return selection
    }

    private func synchronizeRowSelections() {
        let activeIDs = Set(storedItems.lazy.filter(\.isActive).map(\.id))
        let selectedID = storedItems.first(where: \.isActive)?.id
        if selectedID != selectedItemID {
            selectedItemID = selectedID
            selectionRevision &+= 1
        }
        for (id, selection) in rowSelections {
            let active = activeIDs.contains(id)
            if selection.isActive != active { selection.isActive = active }
        }
    }

    func selectDisplayMode(_ displayMode: DisplayMode) {
        revealedItemID = nil
        self.displayMode = displayMode
        isDisplayModeMenuPresented = false
    }

    func toggleDisplayModeMenu() {
        isDisplayModeMenuPresented.toggle()
    }

    @discardableResult
    func revealFile(relativePath: String) -> Bool {
        guard let item = items.first(where: { $0.relativePath == relativePath && !$0.isFolder }) else { return false }
        if !displayedItems.contains(where: { $0.id == item.id }) { displayMode = .files }
        let ancestors = items.filter { $0.isFolder && item.relativePath.hasPrefix($0.relativePath + "/") }.map(\.id)
        collapsedFolderIDs.subtract(ancestors)
        select(item)
        revealedItemID = item.id
        revealRevision &+= 1
        return true
    }

    func toggleFolder(_ item: Item) {
        guard item.isFolder else {
            return
        }
        revealedItemID = nil

        if collapsedFolderIDs.contains(item.id) {
            collapsedFolderIDs.remove(item.id)
        } else {
            collapsedFolderIDs.insert(item.id)
        }
    }

    /// Refresh the real file tree without opening newly discovered folders.
    func replaceItems(_ newItems: [Item]) {
        revealedItemID = nil
        let previousFolderIDs = Set(items.lazy.filter(\.isFolder).map(\.id))
        let newFolderIDs = Set(newItems.lazy.filter(\.isFolder).map(\.id))
        items = newItems
        collapsedFolderIDs = collapsedFolderIDs.intersection(newFolderIDs)
            .union(newFolderIDs.subtracting(previousFolderIDs))
    }

    func isCollapsed(_ item: Item) -> Bool {
        item.isFolder && collapsedFolderIDs.contains(item.id)
    }

    func expandAll() {
        revealedItemID = nil
        collapsedFolderIDs.removeAll()
    }

    func collapseAll() {
        revealedItemID = nil
        collapsedFolderIDs = Set(items.lazy.filter(\.isFolder).map(\.id))
    }

    func toggleAllFolders() {
        isDisplayModeMenuPresented = false
        if hasExpandedFolders { collapseAll() } else { expandAll() }
    }

    private func persistExpandedFolders() {
        guard let expansionPreferenceKey else { return }
        let expandedPaths = items.filter { $0.isFolder && !collapsedFolderIDs.contains($0.id) }.map(\.relativePath).sorted()
        let writeSpan = AdaTrace.startSpan("AdaEditor.FolderPreferences.set")
        defaults.set(expandedPaths, forKey: expansionPreferenceKey)
        writeSpan.end()
        #if os(Windows)
        // The Windows app loop does not automatically flush Foundation preferences.
        let flushSpan = AdaTrace.startSpan("AdaEditor.FolderPreferences.flush")
        defaults.synchronize()
        flushSpan.end()
        #endif
    }

    private static func isHiddenByCollapsedFolder(_ item: Item, collapsedPaths: Set<String>) -> Bool {
        // Check only this item's ancestors. Looking up every collapsed folder in
        // `items` for every file made an expanded Assets tree stall all tab changes.
        var ancestor = item.relativePath[...]
        while let slash = ancestor.lastIndex(of: "/") {
            ancestor = ancestor[..<slash]
            if collapsedPaths.contains(String(ancestor)) { return true }
        }
        return false
    }

    private func isSourceTarget(_ item: Item) -> Bool {
        item.isFolder && item.level == 1 && item.relativePath.hasPrefix("Sources/")
    }
}
