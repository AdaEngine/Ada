//
//  MinValue.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/5/23.
//

/// Restrict minimum possible value for property.
/// If value less than min value, than we set min value
///
/// ```swift
/// @Component
/// struct PlayerHealthBar {
///     @MinValue(0.0) var health: Float
/// }
/// ```
@propertyWrapper
public struct MinValue<T: Comparable & Codable>: Codable {
    let minValue: T

    public var wrappedValue: T {
        didSet {
            self.wrappedValue = Self.applyMinIfNeeded(self.minValue, for: self.wrappedValue)
        }
    }

    public init(wrappedValue: T, _ minValue: T) {
        self.minValue = minValue
        self.wrappedValue = Self.applyMinIfNeeded(minValue, for: wrappedValue)
    }

    static func applyMinIfNeeded(_ min: T, for value: T) -> T {
        return max(min, value)
    }
}

extension MinValue: Sendable where T: Sendable {}
