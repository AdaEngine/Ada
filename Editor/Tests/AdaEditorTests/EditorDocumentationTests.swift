import Foundation
import Testing

@testable import AdaEditor

#if os(macOS)
    import AppKit
    import SwiftUI
#endif

@Suite(.serialized)
@MainActor
struct EditorDocumentationTests {
    @Test
    func bundledGuidesLoadWithoutCheckoutOrNetwork() throws {
        let articles = try EditorDocumentationLibrary.load()
        #expect(articles.count >= 13)
        #expect(Set(articles.map(\.id)).count == articles.count)
        #expect(articles.allSatisfy { !$0.blocks.isEmpty })
        let ids = Set(articles.map(\.id))
        for article in articles {
            for link in article.blocks.flatMap(\.links) where !link.destination.hasPrefix("http") {
                #expect(ids.contains(link.destination))
            }
        }
        let scripting = try #require(articles.first { $0.id == "AdaScripting" })
        #expect(scripting.title == "AdaScript")
        #expect(!scripting.plainText.contains("@Metadata"))
        #expect(scripting.blocks.contains { $0.kind == .code && $0.text.contains("@system(scheduler: \"update\")") })
    }

    @Test
    func searchAndHistoryPreserveNavigation() {
        let model = EditorDocumentationViewModel()
        #expect(model.errorMessage == nil)
        model.searchText = "  component.deltaTime  "
        #expect(model.filteredArticles.isEmpty)
        model.searchText = "  MOVEMENT deltaTime  "
        #expect(model.filteredArticles.contains { $0.id == "AdaScripting" })
        model.select("AdaScripting")
        model.select("AdaScriptViews")
        model.goBack()
        #expect(model.selectedID == "AdaScripting")
        model.goForward()
        #expect(model.selectedID == "AdaScriptViews")
        model.goBack()
        model.select("Building")
        #expect(model.forwardHistory.isEmpty)
        model.select("does-not-exist")
        #expect(model.selectedID == "Building")
    }

    #if os(macOS)
        @Test
        func nativeReaderHostsBundledDocumentation() throws {
            _ = NSApplication.shared
            let model = EditorDocumentationViewModel()
            let window = EditorDocumentationWindowController.makeWindow(viewModel: model)
            defer { window.close() }
            #expect(window.title == "AdaEngine Documentation")
            #expect(window.contentViewController is NSHostingController<EditorDocumentationView>)
            #expect(window.minSize.width == 760)
            model.select("AdaScripting")
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(model.selectedArticle?.title == "AdaScript")
            #expect(model.errorMessage == nil)
        }

        @Test
        func nativeReaderReusesWindowAndRoutesClose() throws {
            _ = NSApplication.shared
            #expect(EditorDocumentationWindowController.open())
            let window = try #require(NSApp.windows.first { $0.title == "AdaEngine Documentation" && $0.isVisible })
            defer { window.close() }
            #expect(EditorDocumentationWindowController.open())
            #expect(NSApp.windows.filter { $0.title == "AdaEngine Documentation" && $0.isVisible }.count == 1)
            // The test runner has no foreground key window. Supply the actual reader window as the routing target.
            #expect(EditorDocumentationWindowController.handleMenuCommand(.closeEditor, keyWindow: nil) == nil)
            #expect(EditorDocumentationWindowController.handleMenuCommand(.closeEditor, keyWindow: window) == true)
            #expect(!window.isVisible)
        }
    #endif
}
