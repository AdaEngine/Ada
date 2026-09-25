//
//  TextEditor.swift
//  AdaEngine
//
//  Created by Codex on 18.05.2026.
//

import AdaText
import AdaUtils
import Math

/// Colors used by a text editor primitive.
public struct TextEditorColors: Hashable, Sendable {
    var background: Color
    var border: Color
    var focusedBorder: Color
    var gutter: Color
    var gutterRule: Color
    var currentLineBackground: Color
    var selection: Color

    /// Creates a text editor color set.
    public init(
        background: Color,
        border: Color,
        focusedBorder: Color,
        gutter: Color,
        gutterRule: Color,
        currentLineBackground: Color,
        selection: Color
    ) {
        self.background = background
        self.border = border
        self.focusedBorder = focusedBorder
        self.gutter = gutter
        self.gutterRule = gutterRule
        self.currentLineBackground = currentLineBackground
        self.selection = selection
    }

    static let standard = Self(
        background: Color.fromHex(0xFAFAFA),
        border: Color.fromHex(0x969696),
        focusedBorder: Color.fromHex(0x2D7EFF),
        gutter: Color.fromHex(0x6F737A),
        gutterRule: Color.fromHex(0xD7D7D7),
        currentLineBackground: Color.fromHex(0x2D7EFF).opacity(0.10),
        selection: Color.fromHex(0x2D7EFF).opacity(0.26)
    )
}

/// A colored token span rendered by ``TextEditor``.
public struct TextEditorTokenSpan: Hashable, Sendable {
    public var line: Int
    public var startColumn: Int
    public var length: Int
    public var color: Color
    /// An optional font override for this token. When omitted, the editor's base font is used.
    public var font: Font?

    public init(line: Int, startColumn: Int, length: Int, color: Color, font: Font? = nil) {
        self.line = line
        self.startColumn = startColumn
        self.length = length
        self.color = color
        self.font = font
    }
}

/// A zero-based source position inside ``TextEditor`` content.
public struct TextEditorSourcePosition: Hashable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// A zero-based source range inside ``TextEditor`` content.
public struct TextEditorSourceRange: Hashable, Sendable {
    public var start: TextEditorSourcePosition
    public var end: TextEditorSourcePosition

    public init(start: TextEditorSourcePosition, end: TextEditorSourcePosition) {
        self.start = start
        self.end = end
    }
}

/// A colored source range rendered as an underline in ``TextEditor``.
public struct TextEditorSourceHighlight: Hashable, Sendable {
    public var range: TextEditorSourceRange
    public var color: Color

    public init(range: TextEditorSourceRange, color: Color) {
        self.range = range
        self.color = color
    }
}

/// A context menu item emitted by ``TextEditor`` source interactions.
public struct TextEditorContextMenuItem {
    public var title: String
    public var action: (() -> Void)?
    public var submenu: [Self]

    public init(title: String, action: (() -> Void)? = nil, submenu: [Self] = []) {
        self.title = title
        self.action = action
        self.submenu = submenu
    }
}

/// A source gutter marker. Lines use the same zero-based coordinates as source positions.
public struct TextEditorLineMarker: Hashable, Sendable {
    public var line: Int
    public var color: Color
    public var isFilled: Bool

    public init(line: Int, color: Color, isFilled: Bool = true) {
        self.line = line
        self.color = color
        self.isFilled = isFilled
    }
}

/// A non-interactive hint aligned with the visible selected text.
public struct TextEditorSelectionHint: Sendable {
    public var text: String
    public var foreground: Color
    public var background: Color
    public var border: Color

    public init(text: String, foreground: Color, background: Color, border: Color) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.border = border
    }
}

/// Optional source-aware interactions for ``TextEditor``.
public struct TextEditorSourceInteraction {
    public var lineMarkers: [TextEditorLineMarker]
    public var gutterHoverColor: Color?
    public var executionLine: Int?
    public var onGutterClick: ((Int) -> Void)?
    public var highlightedRanges: [TextEditorSourceRange]
    public var sourceHighlights: [TextEditorSourceHighlight]
    public var hoveredRange: TextEditorSourceRange?
    public var focusedRange: TextEditorSourceRange?
    public var onHover: ((TextEditorSourcePosition?) -> Void)?
    public var onPrimaryClick: ((TextEditorSourcePosition) -> Void)?
    /// Called when the caret changes, with its source position and bounds in the visible editor viewport.
    public var onCaretViewportRectChange: ((TextEditorSourcePosition, Rect) -> Void)?
    public var onCaretChange: ((TextEditorSourcePosition, String) -> Void)?
    public var onRequestCompletion: ((TextEditorSourcePosition, String) -> Void)?
    public var onMoveCompletionSelection: ((Int) -> Bool)?
    public var onAcceptCompletion: (() -> Bool)?
    /// Return true to accept the selected snippet value and consume Enter.
    public var onAcceptPlaceholder: ((TextEditorSourceRange?) -> Bool)?
    public var onSelectionChange: ((TextEditorSourceRange?, String?) -> Void)?
    public var onChatSelection: ((TextEditorSourceRange, String) -> Void)?
    public var contextMenuItems: ((TextEditorSourcePosition) -> [TextEditorContextMenuItem])?
    public var selectionHint: TextEditorSelectionHint?

    public init(
        lineMarkers: [TextEditorLineMarker] = [],
        gutterHoverColor: Color? = nil,
        executionLine: Int? = nil,
        onGutterClick: ((Int) -> Void)? = nil,
        highlightedRanges: [TextEditorSourceRange] = [],
        sourceHighlights: [TextEditorSourceHighlight] = [],
        hoveredRange: TextEditorSourceRange? = nil,
        focusedRange: TextEditorSourceRange? = nil,
        onHover: ((TextEditorSourcePosition?) -> Void)? = nil,
        onPrimaryClick: ((TextEditorSourcePosition) -> Void)? = nil,
        onCaretViewportRectChange: ((TextEditorSourcePosition, Rect) -> Void)? = nil,
        onCaretChange: ((TextEditorSourcePosition, String) -> Void)? = nil,
        onRequestCompletion: ((TextEditorSourcePosition, String) -> Void)? = nil,
        onMoveCompletionSelection: ((Int) -> Bool)? = nil,
        onAcceptCompletion: (() -> Bool)? = nil,
        onAcceptPlaceholder: ((TextEditorSourceRange?) -> Bool)? = nil,
        onSelectionChange: ((TextEditorSourceRange?, String?) -> Void)? = nil,
        onChatSelection: ((TextEditorSourceRange, String) -> Void)? = nil,
        contextMenuItems: ((TextEditorSourcePosition) -> [TextEditorContextMenuItem])? = nil,
        selectionHint: TextEditorSelectionHint? = nil
    ) {
        self.lineMarkers = lineMarkers
        self.gutterHoverColor = gutterHoverColor
        self.executionLine = executionLine
        self.onGutterClick = onGutterClick
        self.highlightedRanges = highlightedRanges
        self.sourceHighlights = sourceHighlights
        self.hoveredRange = hoveredRange
        self.focusedRange = focusedRange
        self.onHover = onHover
        self.onPrimaryClick = onPrimaryClick
        self.onCaretViewportRectChange = onCaretViewportRectChange
        self.onCaretChange = onCaretChange
        self.onRequestCompletion = onRequestCompletion
        self.onMoveCompletionSelection = onMoveCompletionSelection
        self.onAcceptCompletion = onAcceptCompletion
        self.onAcceptPlaceholder = onAcceptPlaceholder
        self.onSelectionChange = onSelectionChange
        self.onChatSelection = onChatSelection
        self.contextMenuItems = contextMenuItems
        self.selectionHint = selectionHint
    }
}

/// How a text editor finds collapsible source blocks.
public enum TextEditorFoldingStyle: Equatable, Sendable {
    /// Do not show folding controls.
    case none
    /// Match multi-line blocks delimited by braces.
    case braces
    /// Fold lines indented beneath a line ending in a colon.
    case indentation
}

/// A multi-line text editing view.
public struct TextEditor: View {
    let placeholder: String
    let text: Binding<String>
    let tokenSpans: [TextEditorTokenSpan]
    let sourceInteraction: TextEditorSourceInteraction?
    let showsLineNumbers: Bool
    let foldingStyle: TextEditorFoldingStyle
    let showsIndentationGuides: Bool
    let showsTabMarkers: Bool
    let showsSpaceMarkers: Bool
    let highlightsSelectedIdentifier: Bool

    public var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            TextEditorPrimitive(
                placeholder: placeholder,
                text: text,
                tokenSpans: tokenSpans,
                sourceInteraction: sourceInteraction,
                showsLineNumbers: showsLineNumbers,
                foldingStyle: foldingStyle,
                showsIndentationGuides: showsIndentationGuides,
                showsTabMarkers: showsTabMarkers,
                showsSpaceMarkers: showsSpaceMarkers,
                highlightsSelectedIdentifier: highlightsSelectedIdentifier
            )
        }
    }

    /// Creates a text editor.
    ///
    /// - Parameters:
    ///   - placeholder: Text displayed when the editor is empty.
    ///   - text: Two-way binding for the editor content.
    ///   - showsLineNumbers: Whether the source-style gutter and line numbers are visible.
    ///   - showsIndentationMarkers: Compatibility switch for all indentation guides and whitespace markers.
    ///   - showsIndentationGuides: Whether to draw guides at each complete indentation level.
    ///   - showsTabMarkers: Whether to mark leading tab characters.
    ///   - showsSpaceMarkers: Whether to mark leading space characters.
    public init(
        _ placeholder: String = "",
        text: Binding<String>,
        tokenSpans: [TextEditorTokenSpan] = [],
        sourceInteraction: TextEditorSourceInteraction? = nil,
        showsLineNumbers: Bool = true,
        foldingStyle: TextEditorFoldingStyle = .none,
        showsIndentationMarkers: Bool = false,
        showsIndentationGuides: Bool? = nil,
        showsTabMarkers: Bool? = nil,
        showsSpaceMarkers: Bool? = nil,
        highlightsSelectedIdentifier: Bool = false
    ) {
        self.placeholder = placeholder
        self.text = text
        self.tokenSpans = tokenSpans
        self.sourceInteraction = sourceInteraction
        self.showsLineNumbers = showsLineNumbers
        self.foldingStyle = foldingStyle
        self.showsIndentationGuides = showsIndentationGuides ?? showsIndentationMarkers
        self.showsTabMarkers = showsTabMarkers ?? showsIndentationMarkers
        self.showsSpaceMarkers = showsSpaceMarkers ?? showsIndentationMarkers
        self.highlightsSelectedIdentifier = highlightsSelectedIdentifier
    }

    /// Creates a text editor.
    ///
    /// - Parameters:
    ///   - text: Two-way binding for the editor content.
    ///   - showsLineNumbers: Whether the source-style gutter and line numbers are visible.
    ///   - showsIndentationMarkers: Compatibility switch for all indentation guides and whitespace markers.
    ///   - showsIndentationGuides: Whether to draw guides at each complete indentation level.
    ///   - showsTabMarkers: Whether to mark leading tab characters.
    ///   - showsSpaceMarkers: Whether to mark leading space characters.
    public init(
        text: Binding<String>,
        tokenSpans: [TextEditorTokenSpan] = [],
        sourceInteraction: TextEditorSourceInteraction? = nil,
        showsLineNumbers: Bool = true,
        foldingStyle: TextEditorFoldingStyle = .none,
        showsIndentationMarkers: Bool = false,
        showsIndentationGuides: Bool? = nil,
        showsTabMarkers: Bool? = nil,
        showsSpaceMarkers: Bool? = nil,
        highlightsSelectedIdentifier: Bool = false
    ) {
        self.placeholder = ""
        self.text = text
        self.tokenSpans = tokenSpans
        self.sourceInteraction = sourceInteraction
        self.showsLineNumbers = showsLineNumbers
        self.foldingStyle = foldingStyle
        self.showsIndentationGuides = showsIndentationGuides ?? showsIndentationMarkers
        self.showsTabMarkers = showsTabMarkers ?? showsIndentationMarkers
        self.showsSpaceMarkers = showsSpaceMarkers ?? showsIndentationMarkers
        self.highlightsSelectedIdentifier = highlightsSelectedIdentifier
    }
}

struct TextEditorPrimitive: View, ViewNodeBuilder {
    typealias Body = Never
    var body: Never { fatalError("Unreachable code") }

    let placeholder: String
    let text: Binding<String>
    let tokenSpans: [TextEditorTokenSpan]
    let sourceInteraction: TextEditorSourceInteraction?
    let showsLineNumbers: Bool
    let foldingStyle: TextEditorFoldingStyle
    let showsIndentationGuides: Bool
    let showsTabMarkers: Bool
    let showsSpaceMarkers: Bool
    let highlightsSelectedIdentifier: Bool

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TextEditorViewNode(inputs: context, content: self)
    }
}

extension View {
    /// Sets colors for text editors within this view.
    public func textEditorColors(_ colors: TextEditorColors) -> some View {
        self.environment(\.textEditorColors, colors)
    }
}

extension EnvironmentValues {
    @Entry public var textEditorColors: TextEditorColors = .standard
}
