import Foundation
import Observation

struct EditorDocumentationArticle: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let section: String
    let source: String
    let blocks: [EditorDocumentationBlock]

    var plainText: String {
        ([title] + blocks.map(\.text)).joined(separator: "\n\n")
    }
}

struct EditorDocumentationBlock: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case heading, text, code
    }

    struct Link: Decodable, Sendable {
        let title: String
        let destination: String
    }

    let kind: Kind
    let text: String
    let level: Int?
    let language: String?
    let links: [Link]
}

enum EditorDocumentationLibrary {
    static func load(bundle: Bundle = .editor) throws -> [EditorDocumentationArticle] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Assets/Documentation") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([EditorDocumentationArticle].self, from: Data(contentsOf: url))
    }
}

@MainActor
@Observable
final class EditorDocumentationViewModel {
    private(set) var articles: [EditorDocumentationArticle] = []
    private(set) var errorMessage: String?
    private(set) var selectedID: String?
    private(set) var backHistory: [String] = []
    private(set) var forwardHistory: [String] = []
    var searchText = ""

    init() {
        reload()
    }

    var selectedArticle: EditorDocumentationArticle? {
        articles.first { $0.id == selectedID }
    }

    var filteredArticles: [EditorDocumentationArticle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return articles
        }
        return articles.filter { article in
            query.split(whereSeparator: \.isWhitespace)
                .allSatisfy { term in
                    (article.section + " " + article.plainText).localizedStandardContains(String(term))
                }
        }
    }

    func reload() {
        do {
            articles = try EditorDocumentationLibrary.load()
            errorMessage = nil
            selectedID = articles.first?.id
            backHistory = []
            forwardHistory = []
        } catch {
            errorMessage = "The bundled documentation could not be loaded. Try reopening it or reinstalling AdaEditor."
        }
    }

    func select(_ id: String) {
        guard id != selectedID, articles.contains(where: { $0.id == id }) else {
            return
        }
        if let selectedID {
            backHistory.append(selectedID)
        }
        selectedID = id
        forwardHistory = []
    }

    func goBack() {
        guard let id = backHistory.popLast() else {
            return
        }
        if let selectedID {
            forwardHistory.append(selectedID)
        }
        selectedID = id
    }

    func goForward() {
        guard let id = forwardHistory.popLast() else {
            return
        }
        if let selectedID {
            backHistory.append(selectedID)
        }
        selectedID = id
    }
}
