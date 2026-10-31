import Foundation
import Observation
import Synchronization
import Testing

@testable import AdaEditor

@MainActor
extension EditorProjectTreeStateTests {
    @Test("Selection changes invalidate affected rows while tree refresh remains observable")
    func selectionObservationIsLocal() {
        let items = (0..<3).map { index in
            EditorProjectSidebarViewModel.Item(
                id: "File\(index).ada", disclosure: "", icon: "", title: "File\(index).ada",
                relativePath: "File\(index).ada", level: 0, isActive: index == 0, isFolder: false, kind: .text(.ada)
            )
        }
        let model = EditorProjectSidebarViewModel(items: items, displayMode: .files)
        let rows = items.map { model.rowSelection(for: $0) }
        let changes = NavigatorInvalidations()
        withObservationTracking { _ = model.visibleItems.map(\.id) } onChange: { changes.record("tree") }
        withObservationTracking { _ = model.selectedItem } onChange: { changes.record("selection") }
        for index in rows.indices {
            withObservationTracking { _ = rows[index].isActive } onChange: { changes.record("row\(index)") }
        }
        model.select(items[1])
        #expect(changes.count("tree") == 0)
        #expect(changes.count("selection") == 1)
        #expect(changes.count("row0") == 1)
        #expect(changes.count("row1") == 1)
        #expect(changes.count("row2") == 0)
        #expect(model.items.map(\.isActive) == [false, true, false])
        #expect(model.selectedItem?.id == items[1].id)
        withObservationTracking { _ = rows[1].isActive } onChange: { changes.record("reselected") }
        model.select(items[1])
        #expect(changes.count("reselected") == 0)
        model.replaceItems(model.items + [.init(id: "New.ada", disclosure: "", icon: "", title: "New.ada",
            relativePath: "New.ada", level: 0, isActive: false, isFolder: false, kind: .text(.ada))])
        #expect(changes.count("tree") == 1)
        #expect(model.rowSelection(for: items[1]) === rows[1])
    }

    @Test("A large mostly collapsed asset tree keeps folder boundaries and a bounded visibility cost")
    func largeCollapsedAssetTree() throws {
        typealias Item = EditorProjectSidebarViewModel.Item
        func item(_ path: String, level: Int, folder: Bool) -> Item {
            Item(id: "disk:\(path)", disclosure: "", icon: "", title: path.split(separator: "/").last.map(String.init) ?? path,
                 relativePath: path, level: level, isActive: false, isFolder: folder, kind: folder ? .folder : .text(.ada))
        }
        var items = [item("Assets", level: 0, folder: true)]
        var collapsed = Set<String>()
        for index in 0..<400 {
            let path = "Assets/Pack\(index)"
            let folder = item(path, level: 1, folder: true)
            items.append(folder)
            if index != 1 { collapsed.insert(folder.id) }
            for file in 0..<30 { items.append(item("\(path)/File\(file).ada", level: 2, folder: false)) }
        }
        let nested = item("Assets/Pack1/Вложенная папка", level: 2, folder: true)
        items.append(nested)
        items.append(item("\(nested.relativePath)/Hidden.ada", level: 3, folder: false))
        collapsed.insert(nested.id)
        let model = EditorProjectSidebarViewModel(items: items, collapsedFolderIDs: collapsed, displayMode: .files)
        let started = ContinuousClock.now
        let rows = model.visibleItems
        let elapsed = started.duration(to: .now)
        #expect(rows.count == 432)
        #expect(rows.contains { $0.relativePath == "Assets/Pack1/File29.ada" })
        #expect(rows.contains { $0.id == nested.id })
        #expect(!rows.contains { $0.relativePath.hasSuffix("Hidden.ada") })
        #expect(!rows.contains { $0.relativePath == "Assets/Pack10/File0.ada" })
        // This generous UI-stall guard catches the former repeated full-array scans;
        // native before/after measurements use the real project separately.
        #expect(elapsed < .seconds(1))
        print("Navigator visibility: \(items.count) items, \(rows.count) visible, \(elapsed)")
    }
}

private final class NavigatorInvalidations: Sendable {
    private let values = Mutex<[String: Int]>([:])

    func record(_ key: String) { values.withLock { $0[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { values.withLock { $0[key, default: 0] } }
}
