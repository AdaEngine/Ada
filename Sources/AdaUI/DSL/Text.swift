//
//  Text.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaAnimation
import AdaText
import AdaUtils
import Foundation
import Math

/// A view that displays one or more lines of read-only text.
public struct Text {
    let storage: Storage

    /// Creates a text view that displays localized text.
    public init(_ titleKey: LocalizedStringKey) {
        self.storage = Storage(localized: titleKey)
    }

    /// Creates a text view that displays localized text.
    public init(
        _ titleKey: String,
        table: String? = nil,
        bundle: Bundle
    ) {
        self.storage = Storage(
            localized: LocalizedStringKey(
                titleKey,
                table: table,
                bundle: bundle
            )
        )
    }

    /// Creates a text view that displays plain text.
    @_disfavoredOverload
    public init(_ text: String) {
        self.storage = Storage(string: text)
    }

    /// Creates a text view that displays plain text without localization.
    public init(verbatim text: String) {
        self.storage = Storage(string: text)
    }

    /// Creates a text view that displays Markdown content.
    public init(markdown: String) {
        self.storage = Storage(markdown: markdown)
    }

    /// Creates a text view that displays styled attributed content.
    @_disfavoredOverload
    public init(_ attributedText: AttributedText) {
        self.storage = Storage(attributedText: attributedText)
    }

    init(_ storage: Storage) {
        self.storage = storage
    }
}

extension Text: View, ViewNodeBuilder {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    func buildViewNode(in context: BuildContext) -> ViewNode {
        TextViewNode(inputs: context, content: self)
    }
}

extension Text {
    /// Sets the default font for text in this view.
    public func font(_ font: Font?) -> Text {
        if let font {
            self.storage.text.setFont(font, preservingSemanticTraits: true)
        }
        return self
    }

    /// Sets the color of the text displayed by this view.
    public func foregroundColor(_ color: Color) -> Text {
        self.storage.foregroundColor = color
        return self
    }

    /// Sets to a closed range the number of lines that text can occupy in this view.
    public func lineLimit(_ number: Int?) -> Text {
        self.storage.lineLimit = number
        return self
    }

    /// Sets the line break mode for text in this view.
    public func lineBreakMode(_ mode: LineBreakMode) -> Text {
        self.storage.lineBreakMode = mode
        return self
    }

    /// Sets the alignment of text lines in this view.
    public func multilineTextAlignment(_ alignment: TextAlignment) -> Text {
        self.storage.multilineTextAlignment = alignment
        return self
    }

    /// Sets the alignment of text lines in this view.
    public func multilineTextAligment(_ alignment: TextAlignment) -> Text {
        self.multilineTextAlignment(alignment)
    }

    /// Concatenates the text in two text views in a new text view.
    public static func + (lhs: Text, rhs: Text) -> Text {
        let newStorage = lhs.storage.concatinating(other: rhs.storage)
        return Text(newStorage)
    }
}

extension View {
    /// Sets the default font for text in this view.
    public func font(_ font: Font?) -> some View {
        return self.environment(\.font, font)
    }

    /// Sets the default font size for text in this view.
    public func fontSize(_ pointSize: Double) -> some View {
        return self.transformEnvironment(\.font) { font in
            var newFont = font ?? Font.system(size: 17)
            newFont.pointSize = pointSize
            font = newFont
        }
    }

    public func foregroundColor(_ color: Color) -> some View {
        return self.environment(\.foregroundColor, color)
    }

    public func lineLimit(_ number: Int?) -> some View {
        return self.environment(\.lineLimit, number)
    }

    /// Sets the line break mode for text in this view.
    public func lineBreakMode(_ mode: LineBreakMode) -> some View {
        return self.environment(\.lineBreakMode, mode)
    }

    /// Sets the alignment of text lines in this view.
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        return self.environment(\.multilineTextAlignment, alignment)
    }

    /// Sets the alignment of text lines in this view.
    public func multilineTextAligment(_ alignment: TextAlignment) -> some View {
        self.multilineTextAlignment(alignment)
    }
}

extension Text {
    final class Storage {
        var text: AttributedText
        private let preservesExplicitAttributes: Bool
        var foregroundColor: Color?
        var lineLimit: Int?
        var lineBreakMode: LineBreakMode?
        var multilineTextAlignment: TextAlignment?

        init(string: String) {
            self.text = AttributedText(string)
            self.preservesExplicitAttributes = false
        }

        init(localized titleKey: LocalizedStringKey) {
            self.text = AttributedText(titleKey.resolve())
            self.preservesExplicitAttributes = false
        }

        init(markdown: String) {
            self.text = AttributedText(markdown: markdown)
            self.preservesExplicitAttributes = false
        }

        init(attributedText: AttributedText, preservesExplicitAttributes: Bool = true) {
            self.text = attributedText
            self.preservesExplicitAttributes = preservesExplicitAttributes
        }

        func concatinating(other: Storage) -> Storage {
            var newText = self.text
            newText.append(other.text)
            return Storage(
                attributedText: newText,
                preservesExplicitAttributes: self.preservesExplicitAttributes || other.preservesExplicitAttributes
            )
        }

        func applyingEnvironment(_ environment: EnvironmentValues) -> AttributedText {
            if let font = environment.font, !preservesExplicitAttributes {
                self.text.setFont(font, preservingSemanticTraits: true)
            }

            if lineLimit == nil {
                self.lineLimit = environment.lineLimit
            }

            if lineBreakMode == nil {
                self.lineBreakMode = environment.lineBreakMode
            }

            if multilineTextAlignment == nil {
                self.multilineTextAlignment = environment.multilineTextAlignment
            }

            if let foregroundColor = self.foregroundColor {
                self.text.foregroundColor = foregroundColor
            } else if !preservesExplicitAttributes {
                self.text.foregroundColor = environment.foregroundColor ?? .black
            }

            return self.text
        }
    }
}

extension Text {
    public struct Layout: Collection, Equatable, Sequence {
        public typealias Index = Int
        public typealias Element = TextLine

        private let lines: [TextLine]

        init(lines: [TextLine]) {
            self.lines = lines
        }

        public subscript(position: Int) -> TextLine {
            _read {
                yield self.lines[position]
            }
        }

        public var startIndex: Int {
            self.lines.startIndex
        }
        public var endIndex: Int {
            self.lines.endIndex
        }

        public func index(before i: Int) -> Int {
            self.lines.index(before: i)
        }

        public func index(after i: Int) -> Int {
            return self.lines.index(after: i)
        }
    }
}

extension Text {
    public struct Proxy {
        let layoutManager: TextLayoutManager

        public func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
            let width = max(0, proposal.width ?? .infinity)
            let height = max(0, proposal.height ?? .infinity)
            self.layoutManager.fitToSize(Size(width: width, height: height))
            // Preserve fractional typographic dimensions. Pixel snapping belongs
            // to rendering and must not enlarge the parent's constraints.
            return self.layoutManager.size
        }
    }
}

/// A value that can replace the default text view rendering behavior.
public protocol TextRenderer: Animatable, Sendable {
    /// Draws layout into context.
    @MainActor
    func draw(layout: Text.Layout, in context: inout UIGraphicsContext)

    /// Returns the size of the text in proposal. The provided text proxy value may be used to query the sizing behavior of the underlying text layout.
    @MainActor
    func sizeThatFits(proposal: ProposedViewSize, text: Text.Proxy) -> Size
}

extension TextRenderer {
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        // swiftlint:disable:next unused_setter_value
        set {}
    }

    public func sizeThatFits(proposal: ProposedViewSize, text: Text.Proxy) -> Size {
        text.sizeThatFits(proposal)
    }
}

extension View {
    /// Returns a new view such that any text views within it will use renderer to draw themselves.
    /// - Parameter renderer: The renderer value.
    /// - Returns: A new view that will use renderer to draw its text views.
    public func textRendered<T: TextRenderer>(_ renderer: T) -> some View {
        self.environment(\.textRenderer, renderer)
    }
}

extension EnvironmentValues {
    /// Contains instance that can render text. If nil, will use default implementation ``DefaultRichTextRenderer``
    var textRenderer: (any TextRenderer)? {
        get {
            self[TextRendererKey.self]
        }
        set {
            self[TextRendererKey.self] = newValue
        }
    }

    private struct TextRendererKey: EnvironmentKey {
        static let defaultValue: (any TextRenderer)? = nil
    }
}
