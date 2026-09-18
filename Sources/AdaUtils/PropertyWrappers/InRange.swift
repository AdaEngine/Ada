//
//  InRange.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/15/22.
//

/// Create restriction for property value in given range.
///
/// It's works with any comparable types, like Float, Int, Double and so on.
///
/// ```swift
/// @Component
/// struct CircleComponent {
///     @InRange(0...1) var fade: Float = 1
/// }
///
/// var value = CircleComponent()
/// value.fade = 83 // => 1
/// value.fade = 0.3 // => 0.3
/// value.fade = -32 // => 0
/// ```
@propertyWrapper
public struct InRange<T: Comparable & Codable>: Codable {
    let range: Range<T>

    public var wrappedValue: T {
        didSet {
            self.wrappedValue = Self.applyRange(self.range, for: self.wrappedValue)
        }
    }

    public init(wrappedValue: T, _ range: ClosedRange<T>) {
        self.range = unsafe Range(uncheckedBounds: (range.lowerBound, range.upperBound))
        self.wrappedValue = Self.applyRange(self.range, for: wrappedValue)
    }

    public init(wrappedValue: T, _ range: Range<T>) {
        self.range = range
        self.wrappedValue = Self.applyRange(range, for: wrappedValue)
    }

    @inline(__always)
    static func applyRange(_ range: Range<T>, for value: T) -> T {
        if value < range.lowerBound {
            return range.lowerBound
        } else if value > range.upperBound {
            return range.upperBound
        } else {
            return value
        }
    }
}

extension InRange: Sendable where T: Sendable {}
extension InRange: Hashable where T: Hashable {}
extension InRange: Equatable where T: Equatable {}
