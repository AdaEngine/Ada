#if canImport(SwiftUI)
    import Foundation
    import SwiftUI

    struct EditorDocumentationView: View {
        @Bindable var viewModel: EditorDocumentationViewModel
        var onClose: (() -> Void)?

        @Environment(\.openURL) private var openURL
        @State private var copiedItem: String?

        var body: some View {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
            } detail: {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if let error = viewModel.errorMessage {
                        ContentUnavailableView {
                            Label("Documentation Unavailable", systemImage: "book.closed")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry", action: viewModel.reload)
                        }
                    } else if let article = viewModel.selectedArticle {
                        articleContent(article)
                            .id(article.id)
                    }
                }
            }
            .accessibilityIdentifier("AdaEditor.Documentation")
        }

        private var sidebar: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Documentation").font(.title2.bold())
                    Label("Available offline", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Search guides…", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("AdaEditor.Documentation.Search")
                        .padding(.top, 8)
                }
                .padding(16)
                articleList
            }
        }

        private var articleList: some View {
            List(
                selection: Binding(
                    get: { viewModel.selectedID },
                    set: { id in
                        if let id {
                            viewModel.select(id)
                        }
                    }
                )
            ) {
                ForEach(["Editor", "AdaEngine", "AdaScript"], id: \.self) { section in
                    let articles = viewModel.filteredArticles.filter { $0.section == section }
                    if !articles.isEmpty {
                        Section(section == "AdaEngine" ? "Ada" : section) {
                            ForEach(articles) { article in
                                NavigationLink(value: article.id) {
                                    Text(article.title)
                                        .padding(.vertical, 3)
                                }
                                .accessibilityIdentifier("AdaEditor.Documentation.Article.\(article.id)")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if viewModel.filteredArticles.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchText)
                }
            }
        }

        private var toolbar: some View {
            HStack(spacing: 12) {
                Button(action: viewModel.goBack) { Image(systemName: "chevron.left") }
                    .disabled(viewModel.backHistory.isEmpty)
                    .help("Back")
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("AdaEditor.Documentation.Back")
                Button(action: viewModel.goForward) { Image(systemName: "chevron.right") }
                    .disabled(viewModel.forwardHistory.isEmpty)
                    .help("Forward")
                    .accessibilityLabel("Forward")
                    .accessibilityIdentifier("AdaEditor.Documentation.Forward")
                Spacer()
                Button(copiedItem == copyID(-1) ? "Copied" : "Copy Article", systemImage: "doc.on.doc") {
                    if let article = viewModel.selectedArticle {
                        EditorDocumentationWindowController.copy(article.plainText)
                        copiedItem = copyID(-1)
                    }
                }
                .disabled(viewModel.selectedArticle == nil)
                if let onClose {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("AdaEditor.Documentation.Close")
                }
            }
            .buttonStyle(.borderless)
            .padding(16)
        }

        private func articleContent(_ article: EditorDocumentationArticle) -> some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(article.title).font(.largeTitle.bold())
                        DisclosureGroup("On this page") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(article.blocks.indices.filter { article.blocks[$0].kind == .heading }, id: \.self) { index in
                                    Button(article.blocks[index].text) {
                                        proxy.scrollTo(index, anchor: .top)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.tint)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        }
                        ForEach(Array(article.blocks.indices), id: \.self) { index in
                            blockContent(article.blocks[index], index: index)
                                .id(index)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                }
            }
        }

        private func blockContent(_ block: EditorDocumentationBlock, index: Int) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                switch block.kind {
                case .heading:
                    Text(block.text).font((block.level ?? 2) <= 2 ? .title2.bold() : .title3.bold())
                        .padding(.top, 12)
                case .text:
                    Text(inlineMarkdown(block.text))
                        .lineSpacing(5)
                case .code:
                    codeBlock(block, index: index)
                }
                ForEach(Array(block.links.indices), id: \.self) { linkIndex in
                    let link = block.links[linkIndex]
                    let isExternal = link.destination.hasPrefix("https://") || link.destination.hasPrefix("http://")
                    Button(isExternal ? "\(link.title) ↗ (Internet)" : "Read: \(link.title)") {
                        if isExternal, let url = URL(string: link.destination) {
                            openURL(url)
                        } else {
                            viewModel.select(link.destination)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("AdaEditor.Documentation.Link.\(link.destination)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func codeBlock(_ block: EditorDocumentationBlock, index: Int) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(block.language ?? "Code").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(copiedItem == copyID(index) ? "Copied" : "Copy Code", systemImage: "doc.on.doc") {
                        EditorDocumentationWindowController.copy(block.text)
                        copiedItem = copyID(index)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("AdaEditor.Documentation.CopyCode.\(index)")
                }
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }

        private func copyID(_ index: Int) -> String {
            "\(viewModel.selectedID ?? ""):\(index)"
        }

        private func inlineMarkdown(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }
#endif
