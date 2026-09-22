//
//  ComponentReflection.swift
//  AdaEngine
//

import AdaUtils
import Foundation
import Math

/// The runtime shape of a reflected component field.
public enum ReflectedFieldKind: Equatable, Sendable {
    case bool
    case int
    case float
    case string
    case enumeration([String])
    case vector2
    case vector3
    case vector4
    case color
    case assetReference
    case readOnly
}

/// A type-erased value exchanged by runtime component and resource reflection.
public enum ReflectedFieldValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])
}

/// Read and write operations for one reflected component field.
@safe
public struct ReflectedComponentField: @unchecked Sendable {
    public var key: String
    public var label: String
    public var kind: ReflectedFieldKind
    public var isWritable: Bool
    /// Returns whether the reflected Swift field can represent a value without trapping or losing finiteness.
    public var accepts: @Sendable (ReflectedFieldValue) -> Bool
    public var read: @Sendable (any Component) -> ReflectedFieldValue?
    public var write: @Sendable (any Component, ReflectedFieldValue) -> (any Component)?
    /// Reads this field directly from a component column element.
    package var readPointer: (@Sendable (UnsafeRawPointer) -> ReflectedFieldValue?)?
    /// Writes this field directly into a component column element.
    package var writePointer: (@Sendable (UnsafeMutableRawPointer, ReflectedFieldValue) -> Bool)?

    public init(
        key: String,
        label: String,
        kind: ReflectedFieldKind,
        isWritable: Bool,
        accepts: @escaping @Sendable (ReflectedFieldValue) -> Bool = { _ in true },
        read: @escaping @Sendable (any Component) -> ReflectedFieldValue?,
        write: @escaping @Sendable (any Component, ReflectedFieldValue) -> (any Component)?
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isWritable = isWritable
        self.accepts = accepts
        self.read = read
        self.write = write
        unsafe self.readPointer = nil
        unsafe self.writePointer = nil
    }

    @unsafe
    public init(
        key: String,
        label: String,
        kind: ReflectedFieldKind,
        isWritable: Bool,
        accepts: @escaping @Sendable (ReflectedFieldValue) -> Bool = { _ in true },
        read: @escaping @Sendable (any Component) -> ReflectedFieldValue?,
        write: @escaping @Sendable (any Component, ReflectedFieldValue) -> (any Component)?,
        readPointer: (@Sendable (UnsafeRawPointer) -> ReflectedFieldValue?)? = nil,
        writePointer: (@Sendable (UnsafeMutableRawPointer, ReflectedFieldValue) -> Bool)? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isWritable = isWritable
        self.accepts = accepts
        self.read = read
        self.write = write
        unsafe self.readPointer = readPointer
        unsafe self.writePointer = writePointer
    }
}

/// Runtime metadata generated for a component independently of any editor UI.
public struct ReflectedComponentDescriptor: @unchecked Sendable {
    public var typeName: String
    public var displayName: String
    public var requiredComponentTypeNames: [String]
    public var fields: [ReflectedComponentField]

    public init(
        typeName: String,
        displayName: String,
        requiredComponentTypeNames: [String],
        fields: [ReflectedComponentField]
    ) {
        self.typeName = typeName
        self.displayName = displayName
        self.requiredComponentTypeNames = requiredComponentTypeNames
        self.fields = fields
    }

    public init<T: Component>(
        type _: T.Type,
        displayName: String = String(describing: T.self),
        requiredComponentTypeNames: [String],
        fields: [ReflectedComponentField]
    ) {
        self.init(
            typeName: String(reflecting: T.self),
            displayName: displayName,
            requiredComponentTypeNames: requiredComponentTypeNames,
            fields: fields
        )
    }

    public func readPayload(from component: any Component) -> [String: ReflectedFieldValue] {
        fields.reduce(into: [:]) { result, field in
            result[field.key] = field.read(component) ?? .null
        }
    }

    public func writing(_ value: ReflectedFieldValue, toField key: String, in component: any Component) -> (any Component)? {
        fields.first { $0.key == key }?.write(component, value)
    }

    @discardableResult
    public func write(_ value: ReflectedFieldValue, toField key: String, in world: World, entity: Entity.ID) -> Bool {
        guard
            let component = world.getComponent(named: typeName, from: entity),
            let updated = writing(value, toField: key, in: component)
        else {
            return false
        }
        insert(updated, in: world, entity: entity)
        return true
    }

    private func insert(_ component: any Component, in world: World, entity: Entity.ID) {
        func insertTyped<T: Component>(_ component: T) {
            world.insert(component, for: entity)
        }
        _openExistential(component, do: insertTyped)
    }
}

/// An enum whose cases can be represented by component reflection.
public protocol ReflectedEnum: CaseIterable, Sendable {
    var reflectedName: String { get }
    static var reflectedNames: [String] { get }
    static func reflectedCase(named name: String) -> Self?
}

extension ReflectedEnum {
    public var reflectedName: String {
        String(describing: self)
    }

    public static var reflectedNames: [String] {
        allCases.map(\.reflectedName)
    }

    public static func reflectedCase(named name: String) -> Self? {
        allCases.first { $0.reflectedName == name }
    }
}

/// Process-wide descriptors for components registered with the runtime.
public enum ComponentReflectionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: ReflectedComponentDescriptor] = [:]

    public static func register(_ descriptor: ReflectedComponentDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        unsafe descriptors[descriptor.typeName] = descriptor
    }

    public static func descriptor(named typeName: String) -> ReflectedComponentDescriptor? {
        lock.withLock { unsafe descriptors[typeName] }
    }

    public static func allDescriptors() -> [ReflectedComponentDescriptor] {
        lock.withLock { unsafe descriptors.values.sorted { $0.displayName < $1.displayName } }
    }
}

/// Converts supported Swift field types to and from reflected values.
public enum ComponentReflection {
    public static func kind<T>(for _: T.Type) -> ReflectedFieldKind {
        .readOnly
    }

    public static func kind(for _: Bool.Type) -> ReflectedFieldKind { .bool }
    public static func kind(for _: Int.Type) -> ReflectedFieldKind { .int }
    public static func kind(for _: Float.Type) -> ReflectedFieldKind { .float }
    public static func kind(for _: Double.Type) -> ReflectedFieldKind { .float }
    public static func kind(for _: String.Type) -> ReflectedFieldKind { .string }
    public static func kind(for _: Vector2.Type) -> ReflectedFieldKind { .vector2 }
    public static func kind(for _: Vector3.Type) -> ReflectedFieldKind { .vector3 }
    public static func kind(for _: Vector4.Type) -> ReflectedFieldKind { .vector4 }
    public static func kind(for _: Quat.Type) -> ReflectedFieldKind { .vector4 }
    public static func kind(for _: Color.Type) -> ReflectedFieldKind { .color }
    public static func kind<T: ReflectedEnum>(for _: T.Type) -> ReflectedFieldKind { .enumeration(T.reflectedNames) }

    public static func isWritable<T>(_: T.Type) -> Bool {
        false
    }

    public static func isWritable(_: Bool.Type) -> Bool { true }
    public static func isWritable(_: Int.Type) -> Bool { true }
    public static func isWritable(_: Float.Type) -> Bool { true }
    public static func isWritable(_: Double.Type) -> Bool { true }
    public static func isWritable(_: String.Type) -> Bool { true }
    public static func isWritable(_: Vector2.Type) -> Bool { true }
    public static func isWritable(_: Vector3.Type) -> Bool { true }
    public static func isWritable(_: Vector4.Type) -> Bool { true }
    public static func isWritable(_: Quat.Type) -> Bool { true }
    public static func isWritable(_: Color.Type) -> Bool { true }
    public static func isWritable<T: ReflectedEnum>(_: T.Type) -> Bool { true }

    public static func accepts<T>(_: ReflectedFieldValue, for _: T.Type) -> Bool { false }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Bool.Type) -> Bool { fieldValue.boolValue != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Int.Type) -> Bool { fieldValue.intValue != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Float.Type) -> Bool { fieldValue.validFloatValue != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Double.Type) -> Bool { fieldValue.doubleValue?.isFinite == true }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: String.Type) -> Bool {
        if case .string = fieldValue {
            return true
        }
        return false
    }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Vector2.Type) -> Bool { fieldValue.validFloatArray(count: 2) != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Vector3.Type) -> Bool { fieldValue.validFloatArray(count: 3) != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Vector4.Type) -> Bool { fieldValue.validFloatArray(count: 4) != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Quat.Type) -> Bool { fieldValue.validFloatArray(count: 4) != nil }
    public static func accepts(_ fieldValue: ReflectedFieldValue, for _: Color.Type) -> Bool { fieldValue.validColorComponents != nil }
    public static func accepts<T: ReflectedEnum>(_ fieldValue: ReflectedFieldValue, for _: T.Type) -> Bool {
        guard case let .string(string) = fieldValue else {
            return false
        }
        return T.reflectedCase(named: string) != nil
    }

    public static func value(_ fieldValue: ReflectedFieldValue, as _: Bool.Type) -> Bool? { fieldValue.boolValue }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Int.Type) -> Int? { fieldValue.intValue }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Float.Type) -> Float? { fieldValue.validFloatValue }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Double.Type) -> Double? {
        guard let value = fieldValue.doubleValue, value.isFinite else {
            return nil
        }
        return value
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: String.Type) -> String? {
        guard case let .string(value) = fieldValue else {
            return nil
        }
        return value
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Vector2.Type) -> Vector2? {
        fieldValue.validFloatArray(count: 2).map { Vector2($0[0], $0[1]) }
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Vector3.Type) -> Vector3? {
        fieldValue.validFloatArray(count: 3).map { Vector3($0[0], $0[1], $0[2]) }
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Vector4.Type) -> Vector4? {
        fieldValue.validFloatArray(count: 4).map { Vector4($0[0], $0[1], $0[2], $0[3]) }
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Quat.Type) -> Quat? {
        fieldValue.validFloatArray(count: 4).map { Quat(x: $0[0], y: $0[1], z: $0[2], w: $0[3]) }
    }
    public static func value(_ fieldValue: ReflectedFieldValue, as _: Color.Type) -> Color? {
        fieldValue.validColorComponents.map { Color(red: $0[0], green: $0[1], blue: $0[2], alpha: $0[3]) }
    }
    public static func value<T: ReflectedEnum>(_ fieldValue: ReflectedFieldValue, as _: T.Type) -> T? {
        guard case let .string(value) = fieldValue else {
            return nil
        }
        return T.reflectedCase(named: value)
    }

    public static func read<T>(_ value: T) -> ReflectedFieldValue {
        .string(String(describing: value))
    }

    public static func read(_ value: Bool) -> ReflectedFieldValue { .bool(value) }
    public static func read(_ value: Int) -> ReflectedFieldValue { .int(value) }
    public static func read(_ value: Float) -> ReflectedFieldValue { .double(Double(value)) }
    public static func read(_ value: Double) -> ReflectedFieldValue { .double(value) }
    public static func read(_ value: String) -> ReflectedFieldValue { .string(value) }
    public static func read(_ value: Vector2) -> ReflectedFieldValue { .array([.double(Double(value.x)), .double(Double(value.y))]) }
    public static func read(_ value: Vector3) -> ReflectedFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z))]) }
    public static func read(_ value: Vector4) -> ReflectedFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z)), .double(Double(value.w))]) }
    public static func read(_ value: Quat) -> ReflectedFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z)), .double(Double(value.w))]) }
    public static func read(_ value: Color) -> ReflectedFieldValue {
        .object([
            "red": .double(Double(value.red)),
            "green": .double(Double(value.green)),
            "blue": .double(Double(value.blue)),
            "alpha": .double(Double(value.alpha)),
        ])
    }
    public static func read<T: ReflectedEnum>(_ value: T) -> ReflectedFieldValue { .string(value.reflectedName) }

    public static func write<T>(_: ReflectedFieldValue, to _: inout T) -> Bool {
        false
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Bool) -> Bool {
        guard let bool = fieldValue.boolValue else {
            return false
        }
        value = bool
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Int) -> Bool {
        guard let int = fieldValue.intValue else {
            return false
        }
        value = int
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Float) -> Bool {
        guard let float = fieldValue.validFloatValue else {
            return false
        }
        value = float
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Double) -> Bool {
        guard let double = fieldValue.doubleValue, double.isFinite else {
            return false
        }
        value = double
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout String) -> Bool {
        guard case let .string(string) = fieldValue else {
            return false
        }
        value = string
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Vector2) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 2) else {
            return false
        }
        value = Vector2(components[0], components[1])
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Vector3) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 3) else {
            return false
        }
        value = Vector3(components[0], components[1], components[2])
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Vector4) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 4) else {
            return false
        }
        value = Vector4(components[0], components[1], components[2], components[3])
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Quat) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 4) else {
            return false
        }
        value = Quat(x: components[0], y: components[1], z: components[2], w: components[3])
        return true
    }

    public static func write(_ fieldValue: ReflectedFieldValue, to value: inout Color) -> Bool {
        guard let components = fieldValue.validColorComponents else {
            return false
        }
        value = Color(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        return true
    }

    public static func write<T: ReflectedEnum>(_ fieldValue: ReflectedFieldValue, to value: inout T) -> Bool {
        guard
            case let .string(string) = fieldValue,
            let enumValue = T.reflectedCase(named: string)
        else {
            return false
        }
        value = enumValue
        return true
    }
}

extension ReflectedFieldValue {
    public var validFloatValue: Float? {
        guard
            let value = doubleValue,
            value.isFinite,
            abs(value) <= Double(Float.greatestFiniteMagnitude)
        else {
            return nil
        }
        return Float(value)
    }

    public func validFloatArray(count: Int) -> [Float]? {
        guard
            let components = numericArray(count: count),
            components.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) })
        else {
            return nil
        }
        return components.map(Float.init)
    }

    public var validColorComponents: [Float]? {
        guard
            let components = colorComponents,
            components.allSatisfy({ $0.isFinite && abs($0) <= Double(Float.greatestFiniteMagnitude) })
        else {
            return nil
        }
        return components.map(Float.init)
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(value):
            Double(value)
        case let .double(value):
            value
        case let .string(value):
            Double(value)
        default:
            nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            guard
                value.isFinite,
                value >= Double(Int.min),
                value < Double(Int.max) + 1
            else {
                return nil
            }
            return Int(value)
        case let .string(value):
            return Int(value)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value):
            value
        case .string("true"),
            .string("1"):
            true
        case .string("false"),
            .string("0"):
            false
        default:
            nil
        }
    }

    public var colorComponents: [Double]? {
        if let components = numericArray(count: 4) {
            return components
        }
        guard case let .object(object) = self else {
            return nil
        }
        return [
            object["red"]?.doubleValue ?? 0,
            object["green"]?.doubleValue ?? 0,
            object["blue"]?.doubleValue ?? 0,
            object["alpha"]?.doubleValue ?? 1,
        ]
    }

    public func numericArray(count: Int) -> [Double]? {
        guard case let .array(values) = self else {
            return nil
        }
        var numbers: [Double] = []
        numbers.reserveCapacity(count)
        for value in values.prefix(count) {
            guard let number = value.doubleValue else {
                return nil
            }
            numbers.append(number)
        }
        if numbers.count < count {
            numbers.append(contentsOf: Array(repeating: 0, count: count - numbers.count))
        }
        return numbers
    }
}
