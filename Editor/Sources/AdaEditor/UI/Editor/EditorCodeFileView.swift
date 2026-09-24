@_spi(AdaEngine) import AdaEngine
import Foundation
import SwiftTreeSitter
import Synchronization
import TreeSitterSwift

struct EditorCodeFileView: View {
    static let fileSearchFieldIdentifier = "AdaEditor.FileSearch.Query"

    let document: EditorTextDocument
    let text: Binding<String>
    let fontSize: Double
    let fontFamily: EditorCodeFontFamily
    let fontWeight: EditorCodeFontWeight
    let keywordFontWeight: EditorCodeFontWeight
    let colorPalette: EditorCodeColorPalette
    let onSourceHover: ((EditorTextDocument, EditorSourceLocation?) -> Void)?
    let onGoToDefinition: ((EditorTextDocument, EditorSourceLocation) -> Void)?
    let onCompletionPosition: ((EditorTextDocument, EditorSourceLocation, String) -> Void)?
    let onCompletionRequest: ((EditorTextDocument, EditorSourceLocation, String) -> Void)?
    let onApplyCompletion: ((EditorCompletionItem, EditorTextDocument) -> Void)?
    let onMoveCompletionSelection: ((EditorTextDocument, Int) -> Bool)?
    let onAcceptCompletion: ((EditorTextDocument) -> Bool)?
    let onTextSelection: ((EditorTextDocument, EditorSourceRange?, String?) -> Void)?
    let onChatSelection: ((EditorTextDocument, EditorSourceRange, String) -> Void)?
    let sourceContextMenuItems: ((EditorTextDocument, EditorSourceLocation) -> [TextEditorContextMenuItem])?
    var onFileSearchQueryChange: ((String, String) -> Void)?
    var onMoveFileSearchSelection: ((String, Int) -> Void)?
    var onDismissFileSearch: ((String) -> Void)?
    var debugger: EditorDebugger?
    var appearanceSettings: EditorAppearanceSettings = .shared

    @State private var caretViewportRect: Rect?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            codeHeader
            if let documentation = document.symbolDocumentation, !documentation.isEmpty {
                symbolDocumentation(documentation)
            }
            if document.fileSearch.isPresented {
                fileSearchBar
            }
            if let path = document.absolutePath, debugger?.modifiedSources.contains(path) == true {
                Text("Source changed after launch. Restart debugging to use this version.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
                    .padding(.horizontal, 10)
            }
            if let errorMessage = document.errorMessage {
                fileError(message: errorMessage)
            } else {
                codeEditor
                    .overlay(anchor: .topLeading) {
                        ZStack {
                            if let description = document.sourceHoverDescription,
                                !description.isEmpty,
                                document.sourceHoverRange != nil {
                                sourceHoverOverlay(description: description)
                            }
                            if !document.completionItems.isEmpty {
                                completionOverlay
                            }
                        }
                    }
            }
        }
        .background(theme.editorColors.surfaceElevated)
        .accessibilityIdentifier("AdaEditor.CodeFile.\(document.title)")
    }
}

extension EditorCodeFileView {
    private var codeHeader: some View {
        HStack(spacing: 8) {
            Text(document.title)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            Text(document.relativePath)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
            if let statusMessage = document.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(document.isDirty ? theme.editorColors.purple : theme.editorColors.muted)
            }
            Text(document.language.rawValue.uppercased())
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(theme.editorColors.surface)
    }

    private var codeEditor: some View {
        TextEditor(
            text: text,
            tokenSpans: tokenSpans,
            sourceInteraction: sourceInteraction,
            foldingStyle: foldingStyle,
            showsIndentationMarkers: appearanceSettings.showsIndentationMarkers && foldingStyle != .none,
            highlightsSelectedIdentifier: true
        )
            .font(AdaEditorCodeFont.font(family: fontFamily, weight: fontWeight, size: fontSize))
            .foregroundColor(colorPalette.plainText)
            .accentColor(theme.editorColors.blue)
            .textEditorColors(editorColors)
            .drawingGroup()
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var foldingStyle: TextEditorFoldingStyle {
        switch document.language {
        case .yaml:
            .indentation
        case .plainText, .markdown:
            .none
        default:
            .braces
        }
    }

    private func symbolDocumentation(_ documentation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Documentation")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.editorColors.blue)
            Text(
                EditorSourceHoverPresentation.attributedText(
                    EditorSourceHoverPresentation.displayText(from: documentation),
                    language: document.language,
                    palette: colorPalette,
                    font: AdaEditorCodeFont.font(family: fontFamily, weight: fontWeight, size: 11),
                    keywordFont: AdaEditorCodeFont.font(family: fontFamily, weight: keywordFontWeight, size: 11)
                )
            )
            .lineLimit(5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.editorColors.surface)
        .overlay(anchor: .bottomLeading) {
            RectangleShape().fill(theme.editorColors.border.opacity(0.65)).frame(height: 1)
        }
        .accessibilityIdentifier("AdaEditor.SymbolDocumentation")
    }

    private var fileSearchBar: some View {
        let matches = EditorFileSearch.matches(in: document.content, query: document.fileSearch.query)
        let selectedNumber = matches.isEmpty ? 0 : document.fileSearch.selectedIndex + 1

        return HStack(spacing: 8) {
            TextField(
                "Find in file",
                text: Binding(
                    get: { document.fileSearch.query },
                    set: { onFileSearchQueryChange?(document.id, $0) }
                ),
                onSubmit: { onMoveFileSearchSelection?(document.id, 1) }
            )
            .textFieldStyle(PlainTextFieldStyle())
            .font(AdaEditorCodeFont.font(size: 12))
            .foregroundColor(theme.editorColors.text)
            .frame(minWidth: 160, maxWidth: 320)
            .accessibilityIdentifier(Self.fileSearchFieldIdentifier)

            Text("\(selectedNumber) / \(matches.count)")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .frame(width: 58, alignment: .trailing)

            Button("↑") { onMoveFileSearchSelection?(document.id, -1) }
                .buttonStyle(DefaultButtonStyle())
                .disabled(matches.isEmpty)
                .accessibilityIdentifier("AdaEditor.FileSearch.Previous")
            Button("↓") { onMoveFileSearchSelection?(document.id, 1) }
                .buttonStyle(DefaultButtonStyle())
                .disabled(matches.isEmpty)
                .accessibilityIdentifier("AdaEditor.FileSearch.Next")
            Button("×") { onDismissFileSearch?(document.id) }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.FileSearch.Close")
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.editorColors.surface)
        .overlay(anchor: .bottomLeading) {
            RectangleShape().fill(theme.editorColors.border.opacity(0.65)).frame(height: 1)
        }
        .keyboardShortcuts([
            KeyboardShortcutAction(.escape) { onDismissFileSearch?(document.id) },
            KeyboardShortcutAction(.enter, modifiers: .shift) { onMoveFileSearchSelection?(document.id, -1) },
        ])
        .accessibilityIdentifier("AdaEditor.FileSearch.Bar")
    }

    private func completionList(width: Float, height: Float) -> some View {
        let rowWidth = Swift.max(Float.zero, width - EditorCompletionPopupLayout.horizontalPadding * 2)
        let listHeight = Swift.max(Float.zero, height - EditorCompletionPopupLayout.verticalPadding * 2)

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<document.completionItems.count) { index in
                    let item = document.completionItems[index]
                    Button(action: { onApplyCompletion?(item, document) }) {
                        HStack(spacing: 8) {
                            completionKindBadge(item.kind)
                            Text(EditorCompletionPresentation.label(for: item))
                                .font(AdaEditorCodeFont.font(size: 11))
                                .foregroundColor(theme.editorColors.text)
                                .lineLimit(1)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            if let detail = EditorCompletionPresentation.detail(for: item) {
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.editorColors.muted)
                                    .lineLimit(1)
                                    .frame(width: EditorCompletionPopupLayout.detailWidth, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: rowWidth, height: EditorCompletionPopupLayout.rowHeight, alignment: .leading)
                    }
                    .buttonStyle(
                        EditorCompletionButtonStyle(
                            theme: theme,
                            isKeyboardSelected: index == document.selectedCompletionIndex
                        )
                    )
                }
            }
        }
        .frame(width: rowWidth, height: listHeight, alignment: .topLeading)
        .padding(.horizontal, EditorCompletionPopupLayout.horizontalPadding)
        .padding(.vertical, EditorCompletionPopupLayout.verticalPadding)
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
        .overlay {
            RoundedRectangleShape(cornerRadius: 5)
                .stroke(theme.editorColors.border.opacity(0.65), lineWidth: 1)
        }
        .accessibilityIdentifier("AdaEditor.CodeCompletion")
    }

    private var completionOverlay: some View {
        GeometryReader { geometry in
            let popupFrame = EditorCompletionPopupLayout.frame(
                viewportSize: geometry.size,
                caretRect: caretViewportRect,
                itemCount: document.completionItems.count
            )

            completionList(width: popupFrame.width, height: popupFrame.height)
                .frame(width: popupFrame.width, height: popupFrame.height, alignment: .topLeading)
                .offset(x: popupFrame.minX, y: popupFrame.minY)
        }
    }

    private func sourceHoverOverlay(description: String) -> some View {
        GeometryReader { geometry in
            let displayText = EditorSourceHoverPresentation.displayText(from: description)
            let popupFrame = EditorSourceHoverPopupLayout.frame(
                viewportSize: geometry.size,
                hoveredRange: document.sourceHoverRange,
                fontSize: fontSize,
                description: displayText
            )

            Text(
                EditorSourceHoverPresentation.attributedText(
                    displayText,
                    language: document.language,
                    palette: colorPalette,
                    font: AdaEditorCodeFont.font(family: fontFamily, weight: fontWeight, size: 11),
                    keywordFont: AdaEditorCodeFont.font(family: fontFamily, weight: keywordFontWeight, size: 11)
                )
            )
            .lineLimit(EditorSourceHoverPopupLayout.maximumLineCount)
            .padding(EditorSourceHoverPopupLayout.contentPadding)
            .frame(width: popupFrame.width, height: popupFrame.height, alignment: .topLeading)
            .background(RoundedRectangleShape(cornerRadius: 7).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 7)
                    .stroke(theme.editorColors.border.opacity(0.85), lineWidth: 1)
            }
            .offset(x: popupFrame.minX, y: popupFrame.minY)
            .allowsHitTesting(false)
            .accessibilityIdentifier("AdaEditor.SourceHoverDescription")
        }
    }

    private var sourceInteraction: TextEditorSourceInteraction? {
        let supportsLanguageTooling = document.language.supportsLanguageTooling

        return TextEditorSourceInteraction(
            lineMarkers: debugLineMarkers,
            gutterHoverColor: supportsBreakpoints ? Color.red.opacity(0.38) : nil,
            executionLine: debugExecutionLine,
            onGutterClick: gutterClickAction,
            highlightedRanges: document.symbolHighlights.map(\.textEditorRange),
            sourceHighlights: fileSearchHighlights + document.diagnostics.map { diagnostic in
                TextEditorSourceHighlight(range: diagnostic.range.textEditorRange, color: diagnosticColor(for: diagnostic.severity))
            },
            hoveredRange: document.sourceHoverRange?.textEditorRange,
            focusedRange: document.focusedRange?.textEditorRange,
            onHover: { position in
                guard supportsLanguageTooling else {
                    return
                }
                onSourceHover?(document, position.map { EditorSourceLocation(textEditorPosition: $0) })
            },
            onPrimaryClick: { position in
                guard supportsLanguageTooling else {
                    return
                }
                onGoToDefinition?(document, EditorSourceLocation(textEditorPosition: position))
            },
            onCaretViewportRectChange: { _, rect in
                caretViewportRect = rect
            },
            onCaretChange: { position, currentText in
                guard supportsLanguageTooling else {
                    return
                }
                onCompletionPosition?(document, EditorSourceLocation(textEditorPosition: position), currentText)
            },
            onRequestCompletion: { position, currentText in
                guard supportsLanguageTooling else {
                    return
                }
                onCompletionRequest?(document, EditorSourceLocation(textEditorPosition: position), currentText)
            },
            onMoveCompletionSelection: { delta in
                guard supportsLanguageTooling else {
                    return false
                }
                return onMoveCompletionSelection?(document, delta) ?? false
            },
            onAcceptCompletion: {
                guard supportsLanguageTooling else {
                    return false
                }
                return onAcceptCompletion?(document) ?? false
            },
            onSelectionChange: { range, text in
                onTextSelection?(document, range.map { EditorSourceRange(textEditorRange: $0) }, text)
            },
            onChatSelection: { range, text in
                onChatSelection?(document, EditorSourceRange(textEditorRange: range), text)
            },
            contextMenuItems: { position in
                guard supportsLanguageTooling else {
                    return []
                }
                return sourceContextMenuItems?(document, EditorSourceLocation(textEditorPosition: position)) ?? []
            },
            selectionHint: TextEditorSelectionHint(
                text: "Press CMD + L to chat",
                foreground: theme.editorColors.text,
                background: theme.editorColors.surface,
                border: theme.editorColors.border.opacity(0.65)
            )
        )
    }

    private var debugLineMarkers: [TextEditorLineMarker] {
        guard let debugger, let path = document.absolutePath else {
            return []
        }
        let session = document.language == .swift ? debugger.swift : debugger.adaScript
        return debugger.breakpoints.filter { $0.path == path }
            .map { breakpoint in
                TextEditorLineMarker(
                    line: breakpoint.line - 1,
                    color: breakpoint.enabled ? Color.red : theme.editorColors.muted,
                    isFilled: breakpoint.enabled && (!session.state.isActive || session.verifiedBreakpoints[breakpoint.id] == true)
                )
            }
    }

    private var supportsBreakpoints: Bool {
        document.absolutePath != nil && (document.language == .swift || document.language == .ada)
    }

    private var gutterClickAction: ((Int) -> Void)? {
        guard supportsBreakpoints, let path = document.absolutePath else {
            return nil
        }
        return { line in debugger?.toggleBreakpoint(path: path, line: line + 1) }
    }

    private var fileSearchHighlights: [TextEditorSourceHighlight] {
        guard document.fileSearch.isPresented else {
            return []
        }
        return EditorFileSearch.matches(in: document.content, query: document.fileSearch.query)
            .map { TextEditorSourceHighlight(range: $0.textEditorRange, color: Color.yellow.opacity(0.22)) }
    }

    private var debugExecutionLine: Int? {
        guard let debugger, let path = document.absolutePath, !debugger.modifiedSources.contains(path) else {
            return nil
        }
        let session = document.language == .swift ? debugger.swift : debugger.adaScript
        guard session.state == .paused,
            let frame = session.frames.first(where: { $0.id == session.selectedFrameID }),
            let framePath = frame.path,
            URL(fileURLWithPath: framePath).resolvingSymlinksInPath() == URL(fileURLWithPath: path).resolvingSymlinksInPath()
        else {
            return nil
        }
        return frame.line - 1
    }

    private var tokenSpans: [TextEditorTokenSpan] {
        let keywordFont = AdaEditorCodeFont.font(
            family: fontFamily,
            weight: keywordFontWeight,
            size: fontSize
        )
        if document.semanticTokens.isEmpty {
            return EditorSyntaxHighlighter.spans(
                for: document.content,
                language: document.language,
                palette: colorPalette,
                keywordFont: keywordFont
            )
        }

        return document.semanticTokens.map { token in
            TextEditorTokenSpan(
                line: token.line,
                startColumn: token.startCharacter,
                length: token.length,
                color: color(for: token),
                font: token.type == "keyword" || token.type == "macro" ? keywordFont : nil
            )
        }
    }

    private var editorColors: TextEditorColors {
        TextEditorColors(
            background: theme.editorColors.surfaceElevated,
            border: .clear,
            focusedBorder: .clear,
            gutter: colorPalette.lineNumber,
            gutterRule: theme.editorColors.border.opacity(0.45),
            currentLineBackground: colorPalette.currentLineBackground,
            selection: colorPalette.selection
        )
    }

    private func fileError(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unable to open file")
                .font(.system(size: 13))
                .foregroundColor(theme.editorColors.text)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func color(for token: EditorSemanticToken) -> Color {
        switch token.type {
        case "macro", "decorator":
            colorPalette.annotationColor
        case "keyword":
            colorPalette.keyword
        case "class", "enum", "interface", "struct", "type", "typeParameter":
            colorPalette.type
        case "function", "method":
            colorPalette.functionColor
        case "property" where document.language == .ada:
            colorPalette.memberColor
        case "string":
            colorPalette.string
        case "number":
            colorPalette.number
        case "comment":
            colorPalette.comment
        case "operator":
            colorPalette.punctuation
        default:
            colorPalette.plainText
        }
    }

    private func diagnosticColor(for severity: EditorDiagnosticSeverity) -> Color {
        switch severity {
        case .error:
            Color(red: 1, green: 0.28, blue: 0.32)
        case .warning:
            .orange
        case .information:
            theme.editorColors.blue
        case .hint:
            theme.editorColors.muted
        }
    }

    private func completionKindBadge(_ kind: EditorCompletionKind) -> some View {
        Text(kind.badgeTitle)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(kind.badgeColor))
    }
}

struct EditorSourceHoverPopupLayout {
    static let preferredWidth: Float = 520
    static let viewportInset: Float = 12
    static let contentPadding: Float = 12
    static let minimumHeight: Float = 48
    static let maximumLineCount = 8
    static let lineHeight: Float = 18
    static let estimatedCharactersPerLine = 72

    static func frame(
        viewportSize: Size,
        hoveredRange: EditorSourceRange?,
        fontSize: Double,
        description: String
    ) -> Rect {
        let availableWidth = max(0, viewportSize.width - viewportInset * 2)
        let width = min(preferredWidth, availableWidth)
        let logicalLineCount =
            description
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { count, line in
                count + max(1, Int(ceil(Double(line.count) / Double(estimatedCharactersPerLine))))
            }
        let visibleLineCount = min(maximumLineCount, max(1, logicalLineCount))
        let availableHeight = max(0, viewportSize.height - viewportInset * 2)
        let desiredHeight = max(minimumHeight, Float(visibleLineCount) * lineHeight + contentPadding * 2)
        let height = min(desiredHeight, availableHeight)
        let sourceLineHeight = max(18, Float(fontSize) * 1.45)
        let characterAdvance = max(6, Float(fontSize) * 0.58)
        let position = hoveredRange?.start ?? EditorSourceLocation(line: 0, character: 0)
        let desiredX = Float(82) + Float(max(0, position.character)) * characterAdvance
        let sourceLineY = Float(18) + Float(max(0, position.line)) * sourceLineHeight
        let desiredYAbove = sourceLineY - height - Float(8)
        let desiredY = desiredYAbove >= viewportInset ? desiredYAbove : sourceLineY + sourceLineHeight + Float(8)
        let maxX = max(viewportInset, viewportSize.width - width - viewportInset)
        let maxY = max(viewportInset, viewportSize.height - height - viewportInset)

        return Rect(
            x: min(max(viewportInset, desiredX), maxX),
            y: min(max(viewportInset, desiredY), maxY),
            width: width,
            height: height
        )
    }
}

enum EditorSourceHoverPresentation {
    static func displayText(from markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributedText(
        _ text: String,
        language: EditorSourceLanguage,
        palette: EditorCodeColorPalette,
        font: Font,
        keywordFont: Font
    ) -> AttributedText {
        var attributes = TextAttributeContainer()
        attributes.font = font
        attributes.foregroundColor = palette.plainText
        var attributedText = AttributedText(text, attributes: attributes)
        let spans = EditorSyntaxHighlighter.spans(
            for: text,
            language: language,
            palette: palette,
            keywordFont: keywordFont
        )
        let lines = text.components(separatedBy: .newlines)
        var lineOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineOffsets.append(offset)
            offset += line.count + 1
        }

        for span in spans where lines.indices.contains(span.line) {
            let lineLength = lines[span.line].count
            let start = max(0, min(span.startColumn, lineLength))
            let end = max(start, min(span.startColumn + span.length, lineLength))
            guard start < end else { continue }

            var spanAttributes = attributes
            spanAttributes.foregroundColor = span.color
            spanAttributes.font = span.font ?? font
            let startIndex = text.index(text.startIndex, offsetBy: lineOffsets[span.line] + start)
            let endIndex = text.index(text.startIndex, offsetBy: lineOffsets[span.line] + end)
            attributedText.setAttributes(spanAttributes, at: startIndex..<endIndex)
        }
        return attributedText
    }
}

enum EditorCompletionPresentation {
    static func label(for item: EditorCompletionItem) -> String {
        singleLine(item.label, maximumLength: item.detail == nil ? 52 : 34)
    }

    static func detail(for item: EditorCompletionItem) -> String? {
        guard let detail = item.detail, detail != item.label else {
            return nil
        }
        return singleLine(detail, maximumLength: 24)
    }

    static func singleLine(_ value: String, maximumLength: Int) -> String {
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > maximumLength else {
            return normalized
        }
        return String(normalized.prefix(max(1, maximumLength - 1))) + "…"
    }
}

extension EditorCompletionKind {
    var badgeTitle: String {
        switch self {
        case .annotation: "@"
        case .class: "C"
        case .constant: "K"
        case .constructor: "I"
        case .color: "●"
        case .enum: "E"
        case .enumMember: "e"
        case .event: "E"
        case .field: "F"
        case .file: "D"
        case .folder: "F"
        case .function: "ƒ"
        case .interface: "I"
        case .keyword: "#"
        case .method: "M"
        case .module: "N"
        case .operator: "±"
        case .property: "P"
        case .reference: "R"
        case .snippet: "S"
        case .struct: "S"
        case .typeParameter: "T"
        case .text: "T"
        case .unit: "U"
        case .value: "V"
        case .variable: "V"
        case .unknown: "·"
        }
    }

    var badgeColor: Color {
        switch self {
        case .annotation, .keyword:
            Color(red: 0.72, green: 0.33, blue: 0.88)
        case .class, .interface, .struct, .typeParameter:
            Color(red: 0.65, green: 0.31, blue: 0.84)
        case .enum, .enumMember:
            Color(red: 0.95, green: 0.58, blue: 0.08)
        case .function:
            Color(red: 0.22, green: 0.78, blue: 0.36)
        case .constructor, .method:
            Color(red: 0.10, green: 0.55, blue: 0.95)
        case .field, .property:
            Color(red: 0.12, green: 0.68, blue: 0.82)
        case .color:
            Color(red: 0.92, green: 0.34, blue: 0.47)
        case .constant, .event, .operator, .value, .variable:
            Color(red: 0.30, green: 0.58, blue: 0.88)
        case .file, .folder, .module, .reference, .snippet, .text, .unit:
            Color(red: 0.46, green: 0.48, blue: 0.54)
        case .unknown:
            Color(red: 0.40, green: 0.42, blue: 0.47)
        }
    }
}

struct EditorCompletionPopupLayout {
    static let preferredWidth: Float = 420
    static let viewportInset: Float = 12
    static let rowHeight: Float = 28
    static let horizontalPadding: Float = 4
    static let verticalPadding: Float = 4
    static let detailWidth: Float = 118
    static let maximumVisibleRowCount = 10

    static func frame(
        viewportSize: Size,
        caretRect: Rect?,
        itemCount: Int
    ) -> Rect {
        let availableWidth = max(0, viewportSize.width - viewportInset * 2)
        let width = min(preferredWidth, availableWidth)
        let availableHeight = max(0, viewportSize.height - viewportInset * 2)
        let availableRowCount = max(1, Int((availableHeight - verticalPadding * 2) / rowHeight))
        let rowCount = min(maximumVisibleRowCount, availableRowCount, max(1, itemCount))
        let height = min(availableHeight, Float(rowCount) * rowHeight + verticalPadding * 2)
        let caretRect = caretRect ?? Rect(x: viewportInset, y: viewportInset, width: 0, height: 18)
        let desiredX = caretRect.minX
        let desiredYBelow = caretRect.maxY
        let desiredYAbove = caretRect.minY - height
        let desiredY =
            if desiredYBelow + height <= viewportSize.height - viewportInset {
                desiredYBelow
            } else if desiredYAbove >= viewportInset {
                desiredYAbove
            } else {
                desiredYBelow
            }
        let maxX = max(viewportInset, viewportSize.width - width - viewportInset)
        let maxY = max(viewportInset, viewportSize.height - height - viewportInset)

        return Rect(
            x: min(max(viewportInset, desiredX), maxX),
            y: min(max(viewportInset, desiredY), maxY),
            width: width,
            height: height
        )
    }
}

private struct EditorCompletionButtonStyle: ButtonStyle {
    let theme: Theme
    let isKeyboardSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let colors = theme.editorColors
        let backgroundColor =
            if isKeyboardSelected || configuration.isSelected {
                colors.blue.opacity(0.28)
            } else if configuration.isHighlighted {
                colors.border.opacity(0.72)
            } else {
                Color.clear
            }

        return configuration.label
            .background(RoundedRectangleShape(cornerRadius: 3).fill(backgroundColor))
    }
}

extension EditorSourceLocation {
    init(textEditorPosition: TextEditorSourcePosition) {
        self.init(line: textEditorPosition.line, character: textEditorPosition.column)
    }

    var textEditorPosition: TextEditorSourcePosition {
        TextEditorSourcePosition(line: line, column: character)
    }
}

extension EditorSourceRange {
    init(textEditorRange: TextEditorSourceRange) {
        self.init(
            start: EditorSourceLocation(textEditorPosition: textEditorRange.start),
            end: EditorSourceLocation(textEditorPosition: textEditorRange.end)
        )
    }

    var textEditorRange: TextEditorSourceRange {
        TextEditorSourceRange(start: start.textEditorPosition, end: end.textEditorPosition)
    }
}

enum AdaEditorCodeFont {
    private static let lightResource = loadResource(named: "FiraCode-Light")
    private static let regularResource = loadResource(named: "FiraCode-Regular")
    private static let mediumResource = loadResource(named: "FiraCode-Medium")
    private static let semiboldResource = loadResource(named: "FiraCode-SemiBold")
    private static let boldResource = loadResource(named: "FiraCode-Bold")

    static func font(size: Double) -> Font {
        font(family: .firaCode, weight: .medium, size: size)
    }

    static func font(family: EditorCodeFontFamily, weight: EditorCodeFontWeight, size: Double) -> Font {
        guard family == .firaCode, let resource = resource(for: weight) else {
            return .system(size: size, weight: systemWeight(for: weight))
        }

        return Font(fontResource: resource, pointSize: size)
    }

    private static func loadResource(named name: String) -> FontResource? {
        guard
            let fontURL = Foundation.Bundle.editor.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: "Assets/Fonts"
            )
        else {
            return nil
        }

        return FontResource.custom(
            fontPath: fontURL,
            emFontScale: 74,
            includeDefaultCharset: true,
            additionalCodepoints: []
        )
    }

    private static func resource(for weight: EditorCodeFontWeight) -> FontResource? {
        switch weight {
        case .light:
            lightResource
        case .regular:
            regularResource
        case .medium:
            mediumResource
        case .semibold:
            semiboldResource
        case .bold:
            boldResource
        }
    }

    private static func systemWeight(for weight: EditorCodeFontWeight) -> FontWeight {
        switch weight {
        case .light:
            .light
        case .regular, .medium:
            .regular
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }
}

struct EditorCodeToken: Equatable {
    var text: String
    var color: Color
}

private struct EditorSyntaxHighlightSpan: Equatable, Sendable {
    var line: Int
    var startColumn: Int
    var endLine: Int
    var endColumn: Int
    var color: Color
}

private enum EditorTreeSitterSwiftSyntaxHighlighter {
    private static let configuration: LanguageConfiguration? = {
        guard let language = tree_sitter_swift() else {
            return nil
        }

        do {
            return try LanguageConfiguration(language, name: "Swift")
        } catch {
            guard let queriesURL = swiftQueriesDirectoryURL() else {
                return nil
            }

            do {
                return try LanguageConfiguration(language, name: "Swift", queriesURL: queriesURL)
            } catch {
                return nil
            }
        }
    }()

    private static func swiftQueriesDirectoryURL() -> URL? {
        let bundleName = "TreeSitterSwift_TreeSitterSwift.bundle"
        let bundleRoots: [URL] = Bundle.allBundles.flatMap { bundle -> [URL] in
            var roots = [
                bundle.bundleURL,
                bundle.bundleURL.deletingLastPathComponent(),
            ]
            if let resourceURL = bundle.resourceURL {
                roots.append(resourceURL)
            }
            return roots
        }
        let roots =
            bundleRoots
            + [
                Bundle.main.resourceURL,
                Optional(Bundle.main.bundleURL),
                Bundle.main.executableURL?.deletingLastPathComponent(),
                Optional(Bundle.main.bundleURL.deletingLastPathComponent()),
            ]
            .compactMap(\.self)

        for root in roots {
            let bundleURL = root.appendingPathComponent(bundleName, isDirectory: true)
            let queryURLs = [
                bundleURL.appendingPathComponent("queries", isDirectory: true),
                bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true),
            ]

            if let readableURL = queryURLs.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
                return readableURL
            }
        }

        return findSwiftQueriesDirectoryInLocalBuild(bundleName: bundleName)
    }

    private static func findSwiftQueriesDirectoryInLocalBuild(bundleName: String) -> URL? {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let buildDirectories = [
            currentDirectory.appendingPathComponent(".build", isDirectory: true),
            currentDirectory.appendingPathComponent("Editor/.build", isDirectory: true),
        ]

        for buildDirectory in buildDirectories where FileManager.default.fileExists(atPath: buildDirectory.path) {
            guard let enumerator = FileManager.default.enumerator(at: buildDirectory, includingPropertiesForKeys: nil) else {
                continue
            }

            for case let bundleURL as URL in enumerator where bundleURL.lastPathComponent == bundleName {
                let queryURLs = [
                    bundleURL.appendingPathComponent("queries", isDirectory: true),
                    bundleURL.appendingPathComponent("Contents/Resources/queries", isDirectory: true),
                ]

                if let readableURL = queryURLs.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
                    return readableURL
                }
            }
        }

        return nil
    }

    static func spans(for source: String, palette: EditorCodeColorPalette) -> [EditorSyntaxHighlightSpan]? {
        guard let configuration, let query = configuration.queries[.highlights] else {
            return nil
        }

        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            assertionFailure("Unable to configure tree-sitter Swift parser: \(error)")
            return nil
        }

        guard let tree = parser.parse(source) else {
            return nil
        }

        let cursor = query.execute(in: tree)
        let lines = source.components(separatedBy: .newlines)
        return
            cursor
            .resolve(with: .init(string: source))
            .highlights()
            .compactMap { namedRange in
                span(for: namedRange, lines: lines, palette: palette)
            }
    }

    private static func span(
        for namedRange: NamedRange,
        lines: [String],
        palette: EditorCodeColorPalette
    ) -> EditorSyntaxHighlightSpan? {
        let pointRange = namedRange.tsRange.points
        let start = pointRange.lowerBound
        let end = pointRange.upperBound
        let startLine = Int(start.row)
        let endLine = Int(end.row)
        let startColumn = characterColumn(forUTF16ByteColumn: Int(start.column), in: lines[safe: startLine] ?? "")
        let endColumn = characterColumn(forUTF16ByteColumn: Int(end.column), in: lines[safe: endLine] ?? "")
        guard start.row < end.row || startColumn < endColumn else {
            return nil
        }
        guard let color = color(forCaptureName: namedRange.name, palette: palette) else {
            return nil
        }

        return EditorSyntaxHighlightSpan(
            line: startLine,
            startColumn: startColumn,
            endLine: endLine,
            endColumn: endColumn,
            color: color
        )
    }

    private static func characterColumn(forUTF16ByteColumn column: Int, in line: String) -> Int {
        let utf16Offset = min(column / 2, line.utf16.count)
        let index = String.Index(utf16Offset: utf16Offset, in: line)
        return line.distance(from: line.startIndex, to: index)
    }

    private static func color(forCaptureName name: String, palette: EditorCodeColorPalette) -> Color? {
        if name.hasPrefix("comment") {
            return palette.comment
        }

        if name.hasPrefix("string") {
            return palette.string
        }

        if name.hasPrefix("number") || name == "boolean" || name.hasPrefix("constant") {
            return palette.number
        }

        if name == "attribute" {
            return palette.annotationColor
        }
        if name.hasPrefix("function") {
            return palette.functionColor
        }
        if name.hasPrefix("keyword") {
            return palette.keyword
        }

        if name.hasPrefix("type") || name == "constructor" {
            return palette.type
        }

        if name.hasPrefix("punctuation") || name == "operator" {
            return palette.punctuation
        }

        return nil
    }
}

enum EditorSyntaxHighlighter {
    private struct CacheKey: Hashable {
        let source: String
        let language: String
        let palette: EditorCodeColorPalette
        let keywordFont: Font?
    }

    private struct CacheEntry {
        let spans: [TextEditorTokenSpan]
        var lastAccess: UInt64
    }

    private struct CacheState {
        var entries: [CacheKey: CacheEntry] = [:]
        var accessRevision: UInt64 = 0
    }

    private static let maximumCacheEntryCount = 8
    private static let cache = Mutex(CacheState())

    private enum ScanState: Equatable {
        case normal
        case gravityBlockComment(Int)
        case swiftBlockComment
        case swiftMultilineString
    }

    static func tokens(for source: String, language: EditorSourceLanguage, palette: EditorCodeColorPalette) -> [EditorCodeToken] {
        let lines = source.components(separatedBy: .newlines)
        return spans(for: source, language: language, palette: palette)
            .map { span in
                let line = lines[safe: span.line] ?? ""
                let startIndex = line.index(line.startIndex, offsetBy: min(span.startColumn, line.count))
                let endIndex = line.index(startIndex, offsetBy: min(span.length, line.distance(from: startIndex, to: line.endIndex)))
                return EditorCodeToken(text: String(line[startIndex..<endIndex]), color: span.color)
            }
    }

    static func spans(
        for source: String,
        language: EditorSourceLanguage,
        palette: EditorCodeColorPalette,
        keywordFont: Font? = nil
    ) -> [TextEditorTokenSpan] {
        let key = CacheKey(source: source, language: language.rawValue, palette: palette, keywordFont: keywordFont)
        if let cached = cachedSpans(for: key) {
            return cached
        }

        let spans = makeSpans(for: source, language: language, palette: palette)
            .map { span in
                guard span.color == palette.keyword else {
                    return span
                }
                return TextEditorTokenSpan(
                    line: span.line,
                    startColumn: span.startColumn,
                    length: span.length,
                    color: span.color,
                    font: keywordFont
                )
            }
        return cacheSpans(spans, for: key)
    }

    private static func makeSpans(
        for source: String,
        language: EditorSourceLanguage,
        palette: EditorCodeColorPalette
    ) -> [TextEditorTokenSpan] {
        guard supports(language) else {
            return []
        }

        if let treeSitterSpans = treeSitterSwiftSpans(for: source, language: language, palette: palette) {
            return treeSitterSpans
        }

        if language == .glsl || language == .wgsl {
            return EditorShaderSyntaxHighlighter.tokens(for: source, language: language == .glsl ? .glsl : .wgsl)
                .map { token in
                    let color: Color =
                        switch token.kind {
                        case .keyword: palette.keyword
                        case .type: palette.type
                        case .string: palette.string
                        case .number: palette.number
                        case .comment: palette.comment
                        case .punctuation: palette.punctuation
                        }
                    return TextEditorTokenSpan(line: token.line, startColumn: token.column, length: token.length, color: color)
                }
        }

        let lines = source.components(separatedBy: .newlines)
        var state = ScanState.normal
        var spans: [TextEditorTokenSpan] = []

        for (lineIndex, line) in lines.enumerated() {
            switch language {
            case .ada:
                spans += gravitySpans(for: line, lineIndex: lineIndex, state: &state, palette: palette)
            case .swift, .packageManifest:
                spans += swiftSpans(for: line, lineIndex: lineIndex, state: &state, palette: palette)
            case .json:
                spans += jsonSpans(for: line, lineIndex: lineIndex, palette: palette)
            case .yaml:
                spans += yamlSpans(for: line, lineIndex: lineIndex, palette: palette)
            default:
                break
            }
        }

        return spans
    }

    private static func cachedSpans(for key: CacheKey) -> [TextEditorTokenSpan]? {
        cache.withLock { state in
            guard var entry = state.entries[key] else {
                return nil
            }

            state.accessRevision &+= 1
            entry.lastAccess = state.accessRevision
            state.entries[key] = entry
            return entry.spans
        }
    }

    private static func cacheSpans(_ spans: [TextEditorTokenSpan], for key: CacheKey) -> [TextEditorTokenSpan] {
        cache.withLock { state in
            if var entry = state.entries[key] {
                state.accessRevision &+= 1
                entry.lastAccess = state.accessRevision
                state.entries[key] = entry
                return entry.spans
            }

            state.accessRevision &+= 1
            state.entries[key] = CacheEntry(spans: spans, lastAccess: state.accessRevision)
            if state.entries.count > maximumCacheEntryCount,
                let staleKey = state.entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
                state.entries.removeValue(forKey: staleKey)
            }
            return spans
        }
    }

    #if DEBUG
        static func hasCachedSpans(
            for source: String,
            language: EditorSourceLanguage,
            palette: EditorCodeColorPalette
        ) -> Bool {
            let key = CacheKey(source: source, language: language.rawValue, palette: palette, keywordFont: nil)
            return cache.withLock { $0.entries[key] != nil }
        }
    #endif

    private static func treeSitterSwiftSpans(
        for source: String,
        language: EditorSourceLanguage,
        palette: EditorCodeColorPalette
    ) -> [TextEditorTokenSpan]? {
        guard language == .swift || language == .packageManifest,
            let highlightSpans = EditorTreeSitterSwiftSyntaxHighlighter.spans(for: source, palette: palette)
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        var spans: [TextEditorTokenSpan] = []

        for highlightSpan in highlightSpans {
            for lineIndex in highlightSpan.line...highlightSpan.endLine {
                let line = lines[safe: lineIndex] ?? ""
                let startColumn = lineIndex == highlightSpan.line ? highlightSpan.startColumn : 0
                let endColumn = lineIndex == highlightSpan.endLine ? highlightSpan.endColumn : line.count
                appendSpan(line: lineIndex, start: startColumn, end: endColumn, color: highlightSpan.color, to: &spans)
            }
        }

        return spans
    }

    private static func supports(_ language: EditorSourceLanguage) -> Bool {
        switch language {
        case .ada, .glsl, .wgsl, .json, .packageManifest, .swift, .yaml:
            true
        default:
            false
        }
    }

    private static func swiftSpans(
        for line: String,
        lineIndex: Int,
        state: inout ScanState,
        palette: EditorCodeColorPalette
    ) -> [TextEditorTokenSpan] {
        var spans: [TextEditorTokenSpan] = []
        var column = 0
        let characters = Array(line)

        while column < characters.count {
            if state == .swiftBlockComment {
                let end = find("*/", in: characters, from: column)
                let endColumn = end.map { $0 + 2 } ?? characters.count
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.comment, to: &spans)
                column = endColumn
                if end != nil {
                    state = .normal
                }
                continue
            }

            if state == .swiftMultilineString {
                let end = find(#"""""#, in: characters, from: column)
                let endColumn = end.map { $0 + 3 } ?? characters.count
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                if end != nil {
                    state = .normal
                }
                continue
            }

            if matches("//", in: characters, at: column) {
                appendSpan(line: lineIndex, start: column, end: characters.count, color: palette.comment, to: &spans)
                break
            }

            if matches("/*", in: characters, at: column) {
                let end = find("*/", in: characters, from: column + 2)
                let endColumn = end.map { $0 + 2 } ?? characters.count
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.comment, to: &spans)
                column = endColumn
                if end == nil {
                    state = .swiftBlockComment
                }
                continue
            }

            if matches(#"""""#, in: characters, at: column) {
                let end = find(#"""""#, in: characters, from: column + 3)
                let endColumn = end.map { $0 + 3 } ?? characters.count
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                if end == nil {
                    state = .swiftMultilineString
                }
                continue
            }

            if characters[column] == "\"" {
                let endColumn = quotedStringEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                continue
            }

            if isNumberStart(characters, at: column) {
                let endColumn = numberEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.number, to: &spans)
                column = endColumn
                continue
            }

            if isIdentifierStart(characters[column]) {
                let endColumn = identifierEnd(in: characters, from: column)
                let word = String(characters[column..<endColumn])
                if swiftKeywords.contains(word) {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.keyword, to: &spans)
                } else if word.first?.isUppercase == true {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.type, to: &spans)
                }
                column = endColumn
                continue
            }

            if swiftPunctuation.contains(characters[column]) {
                appendSpan(line: lineIndex, start: column, end: column + 1, color: palette.punctuation, to: &spans)
            }

            column += 1
        }

        return spans
    }

    private static func gravitySpans(
        for line: String,
        lineIndex: Int,
        state: inout ScanState,
        palette: EditorCodeColorPalette
    ) -> [TextEditorTokenSpan] {
        var spans: [TextEditorTokenSpan] = []
        var column = 0
        let characters = Array(line)

        while column < characters.count {
            if case .gravityBlockComment(let depth) = state {
                let result = gravityBlockCommentEnd(in: characters, from: column, initialDepth: depth)
                appendSpan(line: lineIndex, start: column, end: result.end, color: palette.comment, to: &spans)
                column = result.end
                state = result.remainingDepth == 0 ? .normal : .gravityBlockComment(result.remainingDepth)
                continue
            }

            if matches("//", in: characters, at: column) {
                appendSpan(line: lineIndex, start: column, end: characters.count, color: palette.comment, to: &spans)
                break
            }

            if matches("/*", in: characters, at: column) {
                let result = gravityBlockCommentEnd(in: characters, from: column, initialDepth: 0)
                appendSpan(line: lineIndex, start: column, end: result.end, color: palette.comment, to: &spans)
                column = result.end
                state = result.remainingDepth == 0 ? .normal : .gravityBlockComment(result.remainingDepth)
                continue
            }

            if characters[column] == "\"" || characters[column] == "'" {
                let endColumn = quotedStringEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                continue
            }
            if characters[column] == "@", column + 1 < characters.count, isIdentifierStart(characters[column + 1]) {
                let endColumn = identifierEnd(in: characters, from: column + 1)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.annotationColor, to: &spans)
                column = endColumn
                continue
            }
            if isNumberStart(characters, at: column) {
                let endColumn = numberEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.number, to: &spans)
                column = endColumn
                continue
            }

            if isIdentifierStart(characters[column]) {
                let endColumn = identifierEnd(in: characters, from: column)
                let word = String(characters[column..<endColumn])
                if gravityKeywords.contains(word.lowercased()) {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.keyword, to: &spans)
                } else if word.first?.isUppercase == true {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.type, to: &spans)
                } else if characters[endColumn...].first(where: { !$0.isWhitespace }) == "(" {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.functionColor, to: &spans)
                } else if characters[..<column].last(where: { !$0.isWhitespace }) == "." {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.memberColor, to: &spans)
                }
                column = endColumn
                continue
            }

            if gravityPunctuation.contains(characters[column]) {
                appendSpan(line: lineIndex, start: column, end: column + 1, color: palette.punctuation, to: &spans)
            }
            column += 1
        }

        return spans
    }

    private static func gravityBlockCommentEnd(
        in characters: [Character],
        from start: Int,
        initialDepth: Int
    ) -> (end: Int, remainingDepth: Int) {
        var depth = initialDepth
        var index = start
        while index < characters.count {
            if matches("/*", in: characters, at: index) {
                depth += 1
                index += 2
            } else if matches("*/", in: characters, at: index) {
                depth -= 1
                index += 2
                if depth == 0 {
                    break
                }
            } else {
                index += 1
            }
        }
        return (index, depth)
    }

    private static func jsonSpans(for line: String, lineIndex: Int, palette: EditorCodeColorPalette) -> [TextEditorTokenSpan] {
        var spans: [TextEditorTokenSpan] = []
        var column = 0
        let characters = Array(line)

        while column < characters.count {
            if characters[column] == "\"" {
                let endColumn = quotedStringEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                continue
            }

            if isNumberStart(characters, at: column) {
                let endColumn = numberEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.number, to: &spans)
                column = endColumn
                continue
            }

            if isIdentifierStart(characters[column]) {
                let endColumn = identifierEnd(in: characters, from: column)
                let word = String(characters[column..<endColumn])
                if jsonKeywords.contains(word) {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.keyword, to: &spans)
                }
                column = endColumn
                continue
            }

            if jsonPunctuation.contains(characters[column]) {
                appendSpan(line: lineIndex, start: column, end: column + 1, color: palette.punctuation, to: &spans)
            }

            column += 1
        }

        return spans
    }

    private static func yamlSpans(for line: String, lineIndex: Int, palette: EditorCodeColorPalette) -> [TextEditorTokenSpan] {
        var spans: [TextEditorTokenSpan] = []
        var column = 0
        let characters = Array(line)

        while column < characters.count {
            if characters[column] == "#" {
                appendSpan(line: lineIndex, start: column, end: characters.count, color: palette.comment, to: &spans)
                break
            }

            if characters[column] == "\"" || characters[column] == "'" {
                let endColumn = quotedStringEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.string, to: &spans)
                column = endColumn
                continue
            }

            if isNumberStart(characters, at: column) {
                let endColumn = numberEnd(in: characters, from: column)
                appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.number, to: &spans)
                column = endColumn
                continue
            }

            if isIdentifierStart(characters[column]) {
                let endColumn = yamlIdentifierEnd(in: characters, from: column)
                let word = String(characters[column..<endColumn])
                let nextNonSpace = characters[endColumn...].firstIndex { !$0.isWhitespace }
                if nextNonSpace.map({ characters[$0] == ":" }) == true {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.type, to: &spans)
                } else if yamlKeywords.contains(word.lowercased()) {
                    appendSpan(line: lineIndex, start: column, end: endColumn, color: palette.keyword, to: &spans)
                }
                column = endColumn
                continue
            }

            if yamlPunctuation.contains(characters[column]) {
                appendSpan(line: lineIndex, start: column, end: column + 1, color: palette.punctuation, to: &spans)
            }

            column += 1
        }

        return spans
    }

    private static func appendSpan(line: Int, start: Int, end: Int, color: Color, to spans: inout [TextEditorTokenSpan]) {
        guard start < end else {
            return
        }

        spans.append(TextEditorTokenSpan(line: line, startColumn: start, length: end - start, color: color))
    }

    private static func matches(_ needle: String, in characters: [Character], at index: Int) -> Bool {
        let needleCharacters = Array(needle)
        guard index + needleCharacters.count <= characters.count else {
            return false
        }

        return Array(characters[index..<index + needleCharacters.count]) == needleCharacters
    }

    private static func find(_ needle: String, in characters: [Character], from index: Int) -> Int? {
        guard index < characters.count else {
            return nil
        }

        for offset in index..<characters.count where matches(needle, in: characters, at: offset) {
            return offset
        }

        return nil
    }

    private static func quotedStringEnd(in characters: [Character], from start: Int) -> Int {
        let quote = characters[start]
        var index = start + 1
        var isEscaped = false

        while index < characters.count {
            let character = characters[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == quote {
                return index + 1
            }
            index += 1
        }

        return characters.count
    }

    private static func numberEnd(in characters: [Character], from start: Int) -> Int {
        var index = start
        if characters[index] == "-" {
            index += 1
        }

        while index < characters.count, characters[index].isNumber {
            index += 1
        }

        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
        }

        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            while index < characters.count, characters[index].isNumber {
                index += 1
            }
        }

        return index
    }

    private static func identifierEnd(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, isIdentifierPart(characters[index]) {
            index += 1
        }
        return index
    }

    private static func yamlIdentifierEnd(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, isYAMLIdentifierPart(characters[index]) {
            index += 1
        }
        return index
    }

    private static func isNumberStart(_ characters: [Character], at index: Int) -> Bool {
        characters[index].isNumber || (characters[index] == "-" && index + 1 < characters.count && characters[index + 1].isNumber)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isYAMLIdentifierPart(_ character: Character) -> Bool {
        isIdentifierPart(character) || character == "-" || character == "."
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension",
        "fallthrough", "false", "for", "func", "guard", "if", "import", "in", "init", "inout", "is", "let", "nil", "operator", "private",
        "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "var", "where", "while",
    ]

    private static let gravityKeywords: Set<String> = [
        "_args", "_func", "and", "break", "case", "class", "const", "continue", "default", "else", "enum", "event", "extern", "false",
        "file", "for", "func", "if", "import", "in", "internal", "is", "lazy", "module", "not", "null", "or", "private", "public", "repeat",
        "return", "static", "struct", "super", "switch", "true", "undefined", "var", "while",
    ]

    private static let jsonKeywords: Set<String> = ["false", "null", "true"]
    private static let yamlKeywords: Set<String> = ["false", "no", "null", "off", "on", "true", "yes"]
    private static let swiftPunctuation = Set("()[]{}.,:;+-*/%=!<>?&|@")
    private static let gravityPunctuation = Set("()[]{}.,:;+-*/%=!<>?&|~^")
    private static let jsonPunctuation = Set("{}[]:,")
    private static let yamlPunctuation = Set("[]{}:,-")
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
