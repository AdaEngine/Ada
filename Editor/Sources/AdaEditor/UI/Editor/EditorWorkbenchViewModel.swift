@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

@Observable
@MainActor
final class EditorWorkbenchViewModel {
    @ObservationIgnored var achievements: EditorAchievementCenter?
    @ObservationIgnored var achievementResourceRoot: URL?
    @ObservationIgnored var achievementAdaScriptProject = false
    @ObservationIgnored var achievementScriptEdits: Set<String> = []
    @ObservationIgnored var achievementRedos: Set<String> = []
    var aiPrompt: String
    var hoveredChip: String?
    var activeEditorTab: String
    var activeOutputTab: String
    var openDocuments: [EditorWorkbenchDocument]
    var tileMapResourceRevision = 0
    var activeDocumentID: String
    var codeColorPalette: EditorCodeColorPalette
    var codeFontSize: Double {
        didSet {
            if codeFontSize.isFinite, (8...48).contains(codeFontSize) {
                UserDefaults.standard.set(codeFontSize, forKey: "AdaEditor.editor.fontSize")
            }
        }
    }
    var codeFontFamily: EditorCodeFontFamily
    var codeFontWeight: EditorCodeFontWeight
    var keywordFontWeight: EditorCodeFontWeight
    var isPreviewEnabled: Bool
    var previewStatus: EditorPreviewStatus
    var uiCatalog: UICatalog = .standard
    var uiCatalogError: String?
    var entityPickerRequest: EditorEntityPickerRequest?
    var modifierPickerRequest: EditorModifierPickerRequest?
    @ObservationIgnored var uiExportLoader = EditorUIExportLoader()
    @ObservationIgnored var uiExportTask: Task<Void, Never>?
    @ObservationIgnored var uiSceneModels: [String: EditorUISceneModel] = [:]
    @ObservationIgnored var tileSourceModels: [String: EditorTileSourceEditorModel] = [:]
    @ObservationIgnored var sceneUndoHistory: [String: [EditorSceneDocument]] = [:]
    @ObservationIgnored var sceneRedoHistory: [String: [EditorSceneDocument]] = [:]
    var selectedPreviewID: String?
    var loadedPreview: EditorLoadedPreview?

    @ObservationIgnored
    var onActiveDocumentChanged: (() -> Void)?
    @ObservationIgnored
    var onActiveDocumentWillChange: (() -> Void)?
    @ObservationIgnored
    var onDocumentEdited: ((String) -> Void)?
    @ObservationIgnored
    var navigationHistory: [String]
    @ObservationIgnored
    var navigationHistoryIndex: Int

    init(
        aiPrompt: String = "",
        hoveredChip: String? = nil,
        activeEditorTab: String = "Main.ascn",
        activeOutputTab: String = "Problems",
        openDocuments: [EditorWorkbenchDocument] = [],
        activeDocumentID: String = "scene:Assets/Scenes/Main.ascn",
        codeColorPalette: EditorCodeColorPalette = .godot,
        codeFontSize: Double = 14,
        codeFontFamily: EditorCodeFontFamily = .firaCode,
        codeFontWeight: EditorCodeFontWeight = .medium,
        keywordFontWeight: EditorCodeFontWeight = .bold,
        isPreviewEnabled: Bool = true,
        previewStatus: EditorPreviewStatus = .hidden,
        selectedPreviewID: String? = nil,
        loadedPreview: EditorLoadedPreview? = nil
    ) {
        self.aiPrompt = aiPrompt
        self.hoveredChip = hoveredChip
        self.activeEditorTab = activeEditorTab
        self.activeOutputTab = activeOutputTab
        self.openDocuments = openDocuments
        self.activeDocumentID = activeDocumentID
        self.codeColorPalette = codeColorPalette
        self.codeFontSize = codeFontSize
        self.codeFontFamily = codeFontFamily
        self.codeFontWeight = codeFontWeight
        self.keywordFontWeight = keywordFontWeight
        self.isPreviewEnabled = isPreviewEnabled
        self.previewStatus = previewStatus
        self.selectedPreviewID = selectedPreviewID
        self.loadedPreview = loadedPreview
        if openDocuments.contains(where: { $0.id == activeDocumentID }) {
            self.navigationHistory = [activeDocumentID]
            self.navigationHistoryIndex = 0
        } else {
            self.navigationHistory = []
            self.navigationHistoryIndex = -1
        }
        EditorUpdateCenter.shared.register(self)
        EditorCloudPreferences.shared.register(self)
    }

    var aiPromptBinding: Binding<String> {
        Binding(get: { self.aiPrompt }, set: { self.aiPrompt = $0 })
    }

    func setActiveDocumentChangedHandler(_ handler: @escaping () -> Void) {
        onActiveDocumentChanged = handler
    }

    func setActiveDocumentWillChangeHandler(_ handler: @escaping () -> Void) {
        onActiveDocumentWillChange = handler
    }

    func setDocumentEditedHandler(_ handler: @escaping (String) -> Void) {
        onDocumentEdited = handler
    }

    var activeDocument: EditorWorkbenchDocument? {
        openDocuments.first { $0.id == activeDocumentID }
    }

    var activeSceneDocument: EditorSceneDocument? {
        guard case let .scene(document)? = activeDocument else {
            return nil
        }

        return document
    }

    func open(_ document: EditorWorkbenchDocument) {
        if let index = openDocuments.firstIndex(where: { $0.id == document.id }) {
            openDocuments[index] = document
        } else {
            openDocuments.append(document)
        }

        selectDocument(id: document.id)
    }

    func moveDocument(id: String, toIndex destinationIndex: Int) {
        guard
            let sourceIndex = openDocuments.firstIndex(where: { $0.id == id }),
            openDocuments.indices.contains(destinationIndex),
            sourceIndex != destinationIndex
        else {
            return
        }

        let document = openDocuments.remove(at: sourceIndex)
        openDocuments.insert(document, at: destinationIndex)
    }

    func selectDocument(id: String) {
        selectDocument(id: id, recordsNavigation: true)
    }

    @discardableResult
    func navigateBack() -> Bool {
        navigateHistory(step: -1)
    }

    @discardableResult
    func navigateForward() -> Bool {
        navigateHistory(step: 1)
    }

    func selectDocument(id: String, recordsNavigation: Bool) {
        guard let document = openDocuments.first(where: { $0.id == id }) else {
            return
        }

        if activeDocumentID != document.id {
            onActiveDocumentWillChange?()
            if recordsNavigation {
                recordNavigation(to: document.id)
            }
            activeDocumentID = document.id
        }

        activeEditorTab = document.title
        onActiveDocumentChanged?()
    }

    func recordNavigation(to documentID: String) {
        if navigationHistory.indices.contains(navigationHistoryIndex), navigationHistory[navigationHistoryIndex] == documentID {
            return
        }

        let firstForwardIndex = navigationHistoryIndex + 1
        if navigationHistory.indices.contains(firstForwardIndex) {
            navigationHistory.removeSubrange(firstForwardIndex...)
        }
        navigationHistory.append(documentID)
        navigationHistoryIndex = navigationHistory.count - 1
    }

    func navigateHistory(step: Int) -> Bool {
        var candidateIndex = navigationHistoryIndex + step
        while navigationHistory.indices.contains(candidateIndex) {
            let documentID = navigationHistory[candidateIndex]
            if documentID != activeDocumentID, openDocuments.contains(where: { $0.id == documentID }) {
                navigationHistoryIndex = candidateIndex
                selectDocument(id: documentID, recordsNavigation: false)
                return true
            }
            candidateIndex += step
        }
        return false
    }

    func closeDocument(id documentID: String) {
        guard let closingIndex = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        let closingDocument = openDocuments[closingIndex]
        if case let .git(document) = closingDocument {
            document.close()
        }
        if closingDocument.isDirty, !saveDocument(closingDocument) {
            return
        }

        let wasActiveDocument = activeDocumentID == documentID
        if wasActiveDocument {
            onActiveDocumentWillChange?()
        }
        openDocuments.remove(at: closingIndex)
        uiSceneModels.removeValue(forKey: documentID)
        tileSourceModels.removeValue(forKey: documentID)
        sceneUndoHistory.removeValue(forKey: documentID)
        sceneRedoHistory.removeValue(forKey: documentID)

        guard wasActiveDocument else {
            return
        }

        guard !openDocuments.isEmpty else {
            activeDocumentID = ""
            activeEditorTab = ""
            onActiveDocumentChanged?()
            return
        }

        let nextIndex = min(closingIndex, openDocuments.count - 1)
        selectDocument(id: openDocuments[nextIndex].id, recordsNavigation: false)
    }

    func discardDocuments(atOrBelow relativePath: String) {
        let discardedIDs = openDocuments.compactMap { document -> String? in
            document.relativePath == relativePath || document.relativePath.hasPrefix("\(relativePath)/") ? document.id : nil
        }
        guard !discardedIDs.isEmpty else {
            return
        }

        let discardedIDSet = Set(discardedIDs)
        let wasActiveDocumentDiscarded = discardedIDSet.contains(activeDocumentID)
        openDocuments.removeAll { discardedIDSet.contains($0.id) }
        uiSceneModels = uiSceneModels.filter { !discardedIDSet.contains($0.key) }
        tileSourceModels = tileSourceModels.filter { !discardedIDSet.contains($0.key) }
        sceneUndoHistory = sceneUndoHistory.filter { !discardedIDSet.contains($0.key) }
        sceneRedoHistory = sceneRedoHistory.filter { !discardedIDSet.contains($0.key) }
        navigationHistory.removeAll { discardedIDSet.contains($0) }
        navigationHistoryIndex = min(navigationHistoryIndex, navigationHistory.count - 1)

        guard wasActiveDocumentDiscarded else {
            return
        }
        guard let nextDocument = openDocuments.first else {
            activeDocumentID = ""
            activeEditorTab = ""
            onActiveDocumentChanged?()
            return
        }
        selectDocument(id: nextDocument.id, recordsNavigation: false)
    }

    func closeOtherDocuments(keeping documentID: String) {
        closeDocuments(withIDs: openDocuments.lazy.filter { $0.id != documentID }.map(\.id))
    }

    func closeDocumentsToLeft(of documentID: String) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }
        closeDocuments(withIDs: openDocuments[..<index].map(\.id))
    }

    func closeDocumentsToRight(of documentID: String) {
        guard let index = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }
        closeDocuments(withIDs: openDocuments[openDocuments.index(after: index)...].map(\.id))
    }

    func closeCleanDocuments() {
        closeDocuments(withIDs: openDocuments.lazy.filter { !$0.isDirty }.map(\.id))
    }

    func closeAllDocuments() {
        closeDocuments(withIDs: openDocuments.map(\.id))
    }

    func closeDocuments<S: Sequence>(withIDs documentIDs: S) where S.Element == String {
        for documentID in documentIDs {
            closeDocument(id: documentID)
        }
    }

    func increaseCodeFontSize() {
        codeFontSize = min(codeFontSize + 1, 28)
    }

    func decreaseCodeFontSize() {
        codeFontSize = max(codeFontSize - 1, 8)
    }

    func resetCodeFontSize() {
        codeFontSize = 14
    }
}
