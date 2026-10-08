//
//  Alignment.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 02.07.2024.
//

/// A horizontal alignment.
public enum HorizontalAlignment: Sendable {
    /// The leading alignment.
    case leading
    /// The trailing alignment.
    case trailing
    /// The center alignment.
    case center
}

/// A vertical alignment.
public enum VerticalAlignment: Sendable {
    /// The top alignment.
    case top
    /// The bottom alignment.
    case bottom
    /// The center alignment.
    case center
}

/// Horizontal and vertical alignment together (SwiftUI-style), e.g. for flexible ``View/frame``.
public struct Alignment: Equatable, Sendable {
    /// Horizontal alignment within the frame.
    public var horizontal: HorizontalAlignment
    /// Vertical alignment within the frame.
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Self(horizontal: .center, vertical: .center)
    public static let leading = Self(horizontal: .leading, vertical: .center)
    public static let trailing = Self(horizontal: .trailing, vertical: .center)
    public static let top = Self(horizontal: .center, vertical: .top)
    public static let bottom = Self(horizontal: .center, vertical: .bottom)
    public static let topLeading = Self(horizontal: .leading, vertical: .top)
    public static let topTrailing = Self(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Self(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Self(horizontal: .trailing, vertical: .bottom)

    /// Corresponding anchor for ``ViewNode/place(in:anchor:proposal:)``.
    public var anchorPoint: AnchorPoint {
        switch (horizontal, vertical) {
        case (.leading, .top): return .topLeading
        case (.center, .top): return .top
        case (.trailing, .top): return .topTrailing
        case (.leading, .center): return .leading
        case (.center, .center): return .center
        case (.trailing, .center): return .trailing
        case (.leading, .bottom): return .bottomLeading
        case (.center, .bottom): return .bottom
        case (.trailing, .bottom): return .bottomTrailing
        }
    }
}

/// A set of axes.
public struct Axis: OptionSet, Sendable {
    /// The raw value of the axis.
    public var rawValue: UInt8

    /// Initialize a new axis.
    ///
    /// - Parameter rawValue: The raw value of the axis.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The horizontal axis.
    public static let horizontal = Self(rawValue: 1 << 0)

    /// The vertical axis.
    public static let vertical = Self(rawValue: 1 << 1)
}
