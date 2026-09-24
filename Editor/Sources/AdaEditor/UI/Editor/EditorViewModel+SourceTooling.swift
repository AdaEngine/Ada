@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

extension EditorViewModel {
    func handleSourceHover(document: EditorTextDocument, position: EditorSourceLocation?) {
        guard let position else {
            latestSourceHoverKey = nil
            workbench.updateTextDocument(id: document.id) { document in
                document.symbolHighlights = []
                document.sourceHoverRange = nil
                document.sourceHoverDescription = nil
            }
            return
        }

        guard supportsSourceNavigation(document) else {
            return
        }

        let hoverKey = "\(document.id):\(position.line):\(position.character)"
        latestSourceHoverKey = hoverKey
        workbench.updateTextDocument(id: document.id) { document in
            document.symbolHighlights = []
            document.sourceHoverRange = nil
            document.sourceHoverDescription = nil
        }

        Task { [weak self] in
            guard let self, let fileURL = document.fileURL else {
                return
            }
            async let highlightsRequest = self.workspaceService.documentHighlights(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )
            async let hoverRequest = self.workspaceService.hover(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )
            let (highlights, hover) = await (highlightsRequest, hoverRequest)
            let hoveredRange =
                hover?.range
                ?? highlights.first(where: { highlight in
                    Self.sourceRange(highlight.range, contains: position)
                })?
                .range

            await MainActor.run {
                guard self.latestSourceHoverKey == hoverKey else {
                    return
                }

                self.workbench.updateTextDocument(id: document.id) { document in
                    document.symbolHighlights = highlights.map(\.range)
                    document.sourceHoverRange = hoveredRange
                    document.sourceHoverDescription = hover?.contents
                }
            }
        }
    }

    static func sourceRange(_ range: EditorSourceRange, contains position: EditorSourceLocation) -> Bool {
        guard position.line >= range.start.line, position.line <= range.end.line else {
            return false
        }
        if position.line == range.start.line, position.character < range.start.character {
            return false
        }
        if position.line == range.end.line, position.character >= range.end.character {
            return false
        }
        return true
    }

    func handleCompletionPosition(document: EditorTextDocument, position: EditorSourceLocation, text: String) {
        completionTask?.cancel()
        completionTask = nil
        workbench.updateTextDocument(id: document.id) { updatedDocument in
            updatedDocument.completionItems = []
            updatedDocument.completionPosition = nil
            updatedDocument.selectedCompletionIndex = 0
        }
        guard supportsCompletions(document), let fileURL = document.fileURL else {
            return
        }
        guard Self.shouldRequestAutomaticCompletion(in: text, at: position) else {
            return
        }

        requestCompletions(document: document, fileURL: fileURL, position: position, text: text, delay: .milliseconds(140))
    }

    nonisolated static func shouldRequestAutomaticCompletion(in text: String, at position: EditorSourceLocation) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line >= 0, position.line < lines.count, position.character > 0 else {
            return false
        }

        let line = lines[position.line]
        guard position.character <= line.count else {
            return false
        }

        let triggerIndex = line.index(line.startIndex, offsetBy: position.character - 1)
        let trigger = line[triggerIndex]
        return trigger == "." || trigger == "_" || trigger.isLetter || trigger.isNumber
    }

    func handleCompletionRequest(document: EditorTextDocument, position: EditorSourceLocation, text: String) {
        guard supportsCompletions(document), let fileURL = document.fileURL else {
            return
        }

        if case let .text(currentDocument)? = workbench.openDocuments.first(where: { $0.id == document.id }),
            !currentDocument.completionItems.isEmpty {
            completionTask?.cancel()
            completionTask = nil
            workbench.updateTextDocument(id: document.id) { updatedDocument in
                updatedDocument.completionItems = []
                updatedDocument.completionPosition = nil
                updatedDocument.selectedCompletionIndex = 0
            }
            return
        }

        completionTask?.cancel()
        completionTask = nil
        requestCompletions(document: document, fileURL: fileURL, position: position, text: text, delay: nil)
    }

    func requestCompletions(
        document: EditorTextDocument,
        fileURL: URL,
        position: EditorSourceLocation,
        text: String,
        delay: Duration?
    ) {
        completionTask = Task { [weak self] in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard let self else {
                return
            }
            let items = await self.workspaceService.completions(
                fileURL: fileURL,
                language: document.language,
                text: text,
                position: position
            )
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self.workbench.updateTextDocument(id: document.id) { updatedDocument in
                    guard updatedDocument.content == text else {
                        return
                    }
                    updatedDocument.completionItems = Array(items.prefix(8))
                    updatedDocument.completionPosition = position
                    updatedDocument.selectedCompletionIndex = 0
                }
                self.completionTask = nil
            }
        }
    }

    func applyCompletion(_ item: EditorCompletionItem, to document: EditorTextDocument) {
        guard
            let position = document.completionPosition,
            let edit = Self.applyingCompletion(item, to: document.content, at: position)
        else {
            return
        }

        workbench.updateTextDocument(id: document.id) { updatedDocument in
            updatedDocument.content = edit.text
            updatedDocument.isDirty = true
            updatedDocument.statusMessage = "Edited"
            updatedDocument.errorMessage = nil
            updatedDocument.completionItems = []
            updatedDocument.completionPosition = nil
            updatedDocument.selectedCompletionIndex = 0
            updatedDocument.focusedRange = EditorSourceRange(start: edit.caret, end: edit.caret)
        }
        completionTask?.cancel()
        completionTask = nil
    }

    @discardableResult
    func moveCompletionSelection(in document: EditorTextDocument, by delta: Int) -> Bool {
        guard
            delta != 0,
            case let .text(currentDocument)? = workbench.openDocuments.first(where: { $0.id == document.id }),
            !currentDocument.completionItems.isEmpty
        else {
            return false
        }

        let lastIndex = currentDocument.completionItems.count - 1
        let currentIndex = min(max(0, currentDocument.selectedCompletionIndex), lastIndex)
        let selectedIndex = min(max(0, currentIndex + delta), lastIndex)
        workbench.updateTextDocument(id: document.id) { updatedDocument in
            updatedDocument.selectedCompletionIndex = selectedIndex
        }
        return true
    }

    @discardableResult
    func applySelectedCompletion(in document: EditorTextDocument) -> Bool {
        guard
            case let .text(currentDocument)? = workbench.openDocuments.first(where: { $0.id == document.id }),
            currentDocument.completionItems.indices.contains(currentDocument.selectedCompletionIndex)
        else {
            return false
        }

        applyCompletion(currentDocument.completionItems[currentDocument.selectedCompletionIndex], to: currentDocument)
        return true
    }

    static func applyingCompletion(
        _ item: EditorCompletionItem,
        to text: String,
        at position: EditorSourceLocation
    ) -> (text: String, caret: EditorSourceLocation)? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(position.line) else {
            return nil
        }

        let range = item.replacementRange ?? inferredCompletionRange(in: lines[position.line], at: position)
        guard
            range.start.line == range.end.line,
            lines.indices.contains(range.start.line),
            range.start.character >= 0,
            range.end.character >= range.start.character,
            range.end.character <= lines[range.start.line].count
        else {
            return nil
        }

        var updatedLines = lines
        let line = updatedLines[range.start.line]
        let start = line.index(line.startIndex, offsetBy: range.start.character)
        let end = line.index(line.startIndex, offsetBy: range.end.character)
        updatedLines[range.start.line].replaceSubrange(start..<end, with: item.insertText)
        let insertedLines = item.insertText.components(separatedBy: .newlines)
        let caret =
            if insertedLines.count == 1 {
                EditorSourceLocation(line: range.start.line, character: range.start.character + item.insertText.count)
            } else {
                EditorSourceLocation(line: range.start.line + insertedLines.count - 1, character: insertedLines.last?.count ?? 0)
            }
        return (
            updatedLines.joined(separator: "\n"),
            caret
        )
    }

    static func inferredCompletionRange(in line: String, at position: EditorSourceLocation) -> EditorSourceRange {
        let characters = Array(line)
        var start = min(max(0, position.character), characters.count)
        while start > 0 {
            let character = characters[start - 1]
            guard character == "_" || character.isLetter || character.isNumber else {
                break
            }
            start -= 1
        }
        return EditorSourceRange(
            start: EditorSourceLocation(line: position.line, character: start),
            end: position
        )
    }

    func receiveSourceDiagnostics(_ diagnostics: [EditorDiagnostic], uri: String) {
        let publishedPath = URL(string: uri)?.path.removingPercentEncoding ?? uri
        let affectedPaths = Set(diagnostics.map(\.filePath) + [publishedPath])

        let firstAffectedIndex = problems.firstIndex { diagnostic in
            diagnostic.isLanguageServiceDiagnostic && affectedPaths.contains(diagnostic.filePath)
        }
        var updatedProblems = problems
        updatedProblems.removeAll { diagnostic in
            diagnostic.isLanguageServiceDiagnostic && affectedPaths.contains(diagnostic.filePath)
        }
        let insertionIndex = min(firstAffectedIndex ?? updatedProblems.endIndex, updatedProblems.endIndex)
        updatedProblems.insert(contentsOf: diagnostics, at: insertionIndex)
        if updatedProblems != problems {
            problems = updatedProblems
        }
        synchronizeOpenDocumentDiagnostics()
        showProblemsIfNeeded()
    }

    func replaceBuildDiagnostics(with diagnostics: [EditorDiagnostic]) {
        problems = Self.replacingBuildDiagnostics(in: problems, with: diagnostics)
        synchronizeOpenDocumentDiagnostics()
    }

    func synchronizeOpenDocumentDiagnostics() {
        for document in workbench.openDocuments {
            guard
                case let .text(textDocument) = document,
                let absolutePath = textDocument.absolutePath
            else {
                continue
            }
            let documentDiagnostics = problems.filter { $0.filePath == absolutePath }
            guard documentDiagnostics != textDocument.diagnostics else {
                continue
            }
            workbench.updateTextDocument(id: textDocument.id) { updatedDocument in
                updatedDocument.diagnostics = documentDiagnostics
            }
        }
    }

    static func replacingBuildDiagnostics(in existing: [EditorDiagnostic], with diagnostics: [EditorDiagnostic]) -> [EditorDiagnostic] {
        existing.filter(\.isLanguageServiceDiagnostic) + diagnostics.filter { !$0.isLanguageServiceDiagnostic }
    }

    func goToDefinition(document: EditorTextDocument, position: EditorSourceLocation) {
        guard supportsSourceNavigation(document), let fileURL = document.fileURL else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            async let targetsRequest = self.workspaceService.definition(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )
            async let hoverRequest = self.workspaceService.hover(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )
            let (targets, hover) = await (targetsRequest, hoverRequest)

            await MainActor.run {
                guard var target = targets.first else {
                    self.appendOutput("No definition found at \(document.relativePath):\(position.line + 1):\(position.character + 1)")
                    return
                }

                target.documentation = hover?.contents ?? target.documentation
                self.openSourceTarget(target)
            }
        }
    }

    func findReferences(document: EditorTextDocument, position: EditorSourceLocation) {
        guard supportsSourceNavigation(document), let fileURL = document.fileURL else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            let references = await self.workspaceService.references(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )

            await MainActor.run {
                self.symbolReferences = references
                self.showBottomPanel = true
                self.selectOutputTab("References")
                self.appendOutput("Found \(references.count) references for \(document.relativePath):\(position.line + 1):\(position.character + 1)")
            }
        }
    }

    func showHoverInfo(document: EditorTextDocument, position: EditorSourceLocation) {
        guard supportsSourceNavigation(document), let fileURL = document.fileURL else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            let hover = await self.workspaceService.hover(
                fileURL: fileURL,
                language: document.language,
                text: document.content,
                position: position
            )

            await MainActor.run {
                self.showBottomPanel = true
                self.selectOutputTab("Output")
                self.appendOutput(hover?.contents ?? "No hover information at \(document.relativePath):\(position.line + 1):\(position.character + 1)")
            }
        }
    }

    func sourceContextMenuItems(document: EditorTextDocument, position: EditorSourceLocation) -> [TextEditorContextMenuItem] {
        guard supportsSourceNavigation(document) else {
            return []
        }

        var items = [
            TextEditorContextMenuItem(title: "Toggle Breakpoint") { [weak self] in
                guard let path = document.absolutePath else {
                    return
                }
                self?.debugger.toggleBreakpoint(path: path, line: position.line + 1)
            },
            TextEditorContextMenuItem(
                title: "Go To",
                submenu: [
                    TextEditorContextMenuItem(title: "Definition") { [weak self] in
                        self?.goToDefinition(document: document, position: position)
                    },
                    TextEditorContextMenuItem(title: "References") { [weak self] in
                        self?.findReferences(document: document, position: position)
                    },
                ]
            ),
            TextEditorContextMenuItem(title: "Show Hover Info") { [weak self] in
                self?.showHoverInfo(document: document, position: position)
            },
            TextEditorContextMenuItem(title: "Document Highlights") { [weak self] in
                self?.handleSourceHover(document: document, position: position)
            },
            TextEditorContextMenuItem(title: "Rename (Unavailable)"),
        ]
        let quickFixes = document.language == .ada
            ? EditorGravityLanguageService.quickFixes(text: document.content, position: position)
            : []
        if quickFixes.isEmpty {
            items.append(TextEditorContextMenuItem(title: "Code Actions (Unavailable)"))
        } else {
            items.append(TextEditorContextMenuItem(
                title: "Code Actions",
                submenu: quickFixes.map { fix in
                    TextEditorContextMenuItem(title: fix.title) { [weak self] in
                        self?.applySourceQuickFix(fix, to: document)
                    }
                }
            ))
        }
        return items
    }

    func applySourceQuickFix(_ fix: EditorSourceQuickFix, to document: EditorTextDocument) {
        workbench.updateTextDocument(id: document.id) { updatedDocument in
            guard let updatedText = Self.applyingSourceQuickFix(fix, to: updatedDocument.content) else {
                return
            }
            updatedDocument.content = updatedText
            updatedDocument.isDirty = true
            updatedDocument.statusMessage = "Edited"
            updatedDocument.errorMessage = nil
            let caret = EditorSourceLocation(
                line: fix.range.start.line,
                character: fix.range.start.character + fix.replacement.count
            )
            updatedDocument.focusedRange = EditorSourceRange(start: caret, end: caret)
        }
    }

    nonisolated static func applyingSourceQuickFix(_ fix: EditorSourceQuickFix, to text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let range = fix.range
        guard
            range.start.line == range.end.line,
            lines.indices.contains(range.start.line),
            range.start.character >= 0,
            range.end.character >= range.start.character,
            range.end.character <= lines[range.start.line].count
        else {
            return nil
        }
        var line = lines[range.start.line]
        let start = line.index(line.startIndex, offsetBy: range.start.character)
        let end = line.index(line.startIndex, offsetBy: range.end.character)
        guard line[start..<end] == fix.originalText else {
            return nil
        }
        line.replaceSubrange(start..<end, with: fix.replacement)
        lines[range.start.line] = line
        return lines.joined(separator: "\n")
    }

    func refreshSemanticTokens(for document: EditorWorkbenchDocument) {
        guard
            case let .text(textDocument) = document,
            textDocument.language.supportsLanguageTooling,
            let absolutePath = textDocument.absolutePath
        else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            if let projectURL = self.projectURL {
                await self.workspaceService.configureSourceWorkspace(projectURL: projectURL)
            }
            await self.workspaceService.setDiagnosticsHandler { [weak self] uri, diagnostics in
                await MainActor.run {
                    self?.receiveSourceDiagnostics(diagnostics, uri: uri)
                }
            }
            let tokens = await self.workspaceService.semanticTokens(
                fileURL: URL(fileURLWithPath: absolutePath, isDirectory: false),
                language: textDocument.language,
                text: textDocument.content
            )
            await MainActor.run {
                self.workbench.applySemanticTokens(tokens, documentID: textDocument.id, source: textDocument.content)
            }
        }
    }

    func supportsSourceNavigation(_ document: EditorTextDocument) -> Bool {
        document.language.supportsLanguageTooling && document.absolutePath != nil
    }

    func supportsCompletions(_ document: EditorTextDocument) -> Bool {
        (document.language == .ada || document.language == .swift || document.language == .packageManifest) && document.absolutePath != nil
    }

    func openSourceTarget(_ target: EditorSourceSymbolTarget) {
        let filePath = target.filePath
        if case let .text(document)? = workbench.openDocuments.first(where: { document in
            if case let .text(textDocument) = document {
                return textDocument.sourceURI == target.uri || textDocument.absolutePath == filePath
            }
            return false
        }) {
            workbench.updateTextDocument(id: document.id) { document in
                document.focusedRange = target.selectionRange
                document.symbolHighlights = [target.selectionRange]
                document.symbolDocumentation = target.documentation
            }
            workbench.selectDocument(id: document.id)
            return
        }

        let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
        let isReferenceDocument = isGeneratedSwiftInterface(target: target, fileURL: fileURL)
        let content: String
        let errorMessage: String?
        if let referenceContent = target.content {
            content = referenceContent
            errorMessage = nil
        } else {
            do {
                content = try String(contentsOf: fileURL, encoding: .utf8)
                errorMessage = nil
            } catch {
                content = ""
                errorMessage = error.localizedDescription
            }
        }

        let relativePath = isReferenceDocument ? generatedInterfacePath(for: target.uri) : relativeProjectPath(for: filePath)
        let isSymbolicLink = !isReferenceDocument && Self.isSymbolicLink(at: fileURL)
        let textDocument = EditorTextDocument(
            id: isReferenceDocument ? "interface:\(target.uri)" : "text:\(relativePath)",
            title: isReferenceDocument ? generatedInterfaceTitle(for: target.uri) : fileURL.lastPathComponent,
            relativePath: relativePath,
            absolutePath: isReferenceDocument ? nil : filePath,
            sourceURI: target.uri,
            language: isReferenceDocument ? .swift : EditorSourceLanguage.detect(fileName: fileURL.lastPathComponent),
            content: content,
            lastSavedContent: errorMessage == nil ? content : nil,
            isReadOnly: isReferenceDocument || isSymbolicLink || errorMessage != nil,
            errorMessage: errorMessage,
            statusMessage: isReferenceDocument
                ? "Read-only: generated Swift interface"
                : isSymbolicLink ? "Read-only: symbolic link" : errorMessage == nil ? nil : "Read-only: unable to read as UTF-8",
            symbolHighlights: [target.selectionRange],
            focusedRange: target.selectionRange,
            symbolDocumentation: target.documentation
        )
        let workbenchDocument = EditorWorkbenchDocument.text(textDocument)
        workbench.open(workbenchDocument)
        if !isReferenceDocument {
            refreshSemanticTokens(for: workbenchDocument)
        }
    }

    func generatedInterfaceTitle(for uri: String) -> String {
        let name = URL(string: uri)?.lastPathComponent.removingPercentEncoding
        return name?.isEmpty == false ? name ?? "Swift Interface" : "Swift Interface"
    }

    func generatedInterfacePath(for uri: String) -> String {
        "Generated Interfaces/\(generatedInterfaceTitle(for: uri))"
    }

    func isGeneratedSwiftInterface(target: EditorSourceSymbolTarget, fileURL: URL) -> Bool {
        let scheme = URL(string: target.uri)?.scheme?.lowercased()
        return scheme == "sourcekit-lsp"
            || fileURL.pathExtension.lowercased() == "swiftinterface"
            || fileURL.path.contains("/sourcekit-lsp/GeneratedInterfaces/")
    }

    func relativeProjectPath(for filePath: String) -> String {
        guard let projectURL else {
            return filePath
        }

        let projectPath = projectURL.path
        guard filePath.hasPrefix(projectPath) else {
            return filePath
        }

        let start = filePath.index(filePath.startIndex, offsetBy: projectPath.count)
        return String(filePath[start...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension EditorTextDocument {
    var fileURL: URL? {
        absolutePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }
}
