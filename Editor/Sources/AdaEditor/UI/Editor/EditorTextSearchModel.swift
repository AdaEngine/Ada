import Foundation
import Observation

@Observable
@MainActor
final class EditorTextSearchModel {
    var isPresented = false
    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var results = EditorTextSearchResults()
    var selectedID: String?
    var isSearching = false
    var errorMessage: String?
    @ObservationIgnored private let service = EditorTextSearchService()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var selectedMatch: EditorTextSearchMatch? { results.matches.first { $0.id == selectedID } }
    var status: String {
        if let errorMessage {
            return errorMessage
        }
        if isSearching {
            return "Searching…"
        }
        if query.isEmpty {
            return "Enter text to search in project files"
        }
        let files = Set(results.matches.map(\.filePath)).count
        return "\(results.matches.count)\(results.isTruncated ? "+" : "") matches in \(files) files"
    }

    func search(root: URL?, openBuffers: [String: String]) {
        task?.cancel()
        generation += 1
        let currentGeneration = generation
        results = EditorTextSearchResults()
        selectedID = nil
        errorMessage = nil
        isSearching = false
        guard let root else {
            errorMessage = "Open a project to search its files"
            return
        }
        guard !query.isEmpty else {
            return
        }
        isSearching = true
        let query = query
        let caseSensitive = caseSensitive
        let wholeWord = wholeWord
        task = Task { [weak self, service] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let results = try await service.search(
                    root: root,
                    query: query,
                    caseSensitive: caseSensitive,
                    wholeWord: wholeWord,
                    openBuffers: openBuffers
                )
                guard let self, !Task.isCancelled, generation == currentGeneration else {
                    return
                }
                self.results = results
                selectedID = results.matches.first?.id
                isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, generation == currentGeneration else {
                    return
                }
                errorMessage = error.localizedDescription
                isSearching = false
            }
        }
    }

    func moveSelection(by delta: Int) {
        guard !results.matches.isEmpty else {
            return
        }
        let index = results.matches.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results.matches[min(max(0, index + delta), results.matches.count - 1)].id
    }

    func close() {
        task?.cancel()
        generation += 1
        isSearching = false
        isPresented = false
    }
}

extension EditorViewModel {
    func presentTextSearch() {
        toolbar.clearSearch()
        textSearch.isPresented = true
        refreshTextSearch()
    }

    func refreshTextSearch() {
        var buffers: [String: String] = [:]
        for document in workbench.openDocuments {
            if case let .text(text) = document, let path = text.absolutePath {
                buffers[path] = text.content
            }
        }
        textSearch.search(root: projectURL, openBuffers: buffers)
    }

    func openTextSearchMatch(_ match: EditorTextSearchMatch) {
        textSearch.close()
        let targetURL = URL(fileURLWithPath: match.filePath).standardizedFileURL.resolvingSymlinksInPath()
        // Keep the existing document identity even when macOS spells a path via /private.
        let existingPath = workbench.openDocuments
            .compactMap { document -> String? in
                guard case let .text(text) = document, let path = text.absolutePath else {
                    return nil
                }
                return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == targetURL ? path : nil
            }
            .first
        let filePath = existingPath ?? match.filePath
        openSourceTarget(
            EditorSourceSymbolTarget(
                uri: URL(fileURLWithPath: filePath).absoluteString,
                filePath: filePath,
                range: match.range,
                selectionRange: match.range
            )
        )
    }
}
