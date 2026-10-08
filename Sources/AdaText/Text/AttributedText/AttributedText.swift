//
//  AttributedText.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/5/23.
//

import OrderedCollections

// TODO: Move to Swift-Foundation and use AttributedString instead of our version.

/// A value type for a string with associated attributes for portions of its text.
@dynamicMemberLookup
public struct AttributedText: Hashable, Sendable {
    public enum AttributeMergePolicy {
        case keepNew
        case keepOld
    }

    public internal(set) var text: String

    @usableFromInline
    var attributes: OrderedDictionary<String.Index, TextAttributeContainer> = [:]

    public init(_ text: String, attributes: TextAttributeContainer = TextAttributeContainer()) {
        self.text = text

        for index in text.indices {
            self.attributes[index] = attributes
        }
    }

    /// Creates attributed text by parsing Markdown.
    public init(
        markdown: String,
        attributes: TextAttributeContainer = TextAttributeContainer(),
        options: TextMarkdownOptions = TextMarkdownOptions()
    ) {
        self = TextMarkdownPlugin.parse(markdown, attributes: attributes, options: options)
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<TextAttributeContainer, T>) -> T {
        get {
            self.attributes(at: self.startIndex)[keyPath: keyPath]
        }

        set {
            let range = self.text.startIndex..<self.text.endIndex

            for index in self.text[range].indices {
                var container = self.attributes(at: index)
                container[keyPath: keyPath] = newValue
                self.setAttributes(container, at: index)
            }
        }
    }
}

extension AttributedText {
    public mutating func append(_ string: AttributedText) {
        let endIndex = self.text.endIndex
        let newText = self.text + string.text
        let indicies = newText[endIndex...].indices

        for (newIndex, attribute) in zip(indicies, string.attributes.elements.values) {
            self.attributes[newIndex] = attribute
        }

        self.text = newText
    }
}

extension AttributedText {
    public func attributes(at index: String.Index) -> TextAttributeContainer {
        if index > self.text.endIndex || index < self.text.startIndex {
            fatalError("Index bound of range")
        }

        return self.attributes[index] ?? TextAttributeContainer()
    }

    public mutating func settingAttributes(_ container: TextAttributeContainer) {
        self.attributes.removeAll(keepingCapacity: true)

        for index in self.text.indices {
            self.attributes[index] = container
        }
    }

    public mutating func mergeAttributes(_ attributes: TextAttributeContainer, mergePolicy: AttributedText.AttributeMergePolicy = .keepNew) {
        let range = startIndex..<endIndex

        for index in text[range].indices {
            var container = self.attributes(at: index)
            container.merge(attributes, mergePolicy: mergePolicy)
            self.setAttributes(container, at: index)
        }
    }

    public mutating func setAttributes(
        _ container: TextAttributeContainer,
        at range: Range<String.Index>
    ) {
        for index in self.text[range].indices {
            self.attributes[index] = container
        }
    }

    public mutating func setAttributes(
        _ container: TextAttributeContainer,
        at index: String.Index
    ) {
        self.attributes[index] = container
    }

    /// Applies a base font while preserving semantic font traits and relative scales.
    public mutating func setFont(_ font: Font, preservingSemanticTraits: Bool) {
        let range = startIndex..<endIndex

        for index in text[range].indices {
            var container = self.attributes(at: index)
            if preservingSemanticTraits {
                container.font = font.applyingTraits(container.fontTraits, scale: container.fontScale)
            } else {
                container.font = font
            }
            self.setAttributes(container, at: index)
        }
    }
}

extension AttributedText: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value, attributes: TextAttributeContainer())
    }
}

extension AttributedText {
    @inlinable
    @inline(__always)
    public static func + (lhs: AttributedText, rhs: AttributedText) -> AttributedText {
        var newString = lhs
        newString.append(rhs)
        return newString
    }

    @inlinable
    @inline(__always)
    public static func += (lhs: inout AttributedText, rhs: AttributedText) {
        lhs.append(rhs)
    }
}

extension AttributedText: RandomAccessCollection {
    public typealias Index = String.Index

    public var startIndex: Index {
        return self.text.startIndex
    }

    public var endIndex: Index {
        return self.text.endIndex
    }

    // TODO: Maybe we should use instance SlicedAttributedText ???
    public subscript(position: Index) -> AttributedText {
        _read {
            if position < self.startIndex || position > self.endIndex {
                fatalError("Index out of range")
            }

            let text = self.text[position]
            let container = self.attributes[position] ?? TextAttributeContainer()
            let attribute = AttributedText(String(text), attributes: container)

            yield attribute
        }
    }

    public func index(before i: Index) -> Index {
        self.text.index(before: i)
    }

    public func index(after i: Index) -> Index {
        self.text.index(after: i)
    }
}
