//
//  EditorComponentReflection.swift
//  AdaEngine
//

import AdaUtils
import Foundation
import Math

public enum EditorFieldKind: Equatable, Sendable {
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

public enum EditorFieldValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])
}

@safe
public struct EditorComponentFieldDescriptor: @unchecked Sendable {
    public var key: String
    public var label: String
    public var kind: EditorFieldKind
    public var isEditable: Bool
    /// Returns whether the reflected Swift field can represent a value without trapping or losing finiteness.
    public var accepts: @Sendable (EditorFieldValue) -> Bool
    public var read: @Sendable (any Component) -> EditorFieldValue?
    public var write: @Sendable (any Component, EditorFieldValue) -> (any Component)?
    /// Reads this field directly from a component column element.
    package var readPointer: (@Sendable (UnsafeRawPointer) -> EditorFieldValue?)?
    /// Writes this field directly into a component column element.
    package var writePointer: (@Sendable (UnsafeMutableRawPointer, EditorFieldValue) -> Bool)?

    public init(
        key: String,
        label: String,
        kind: EditorFieldKind,
        isEditable: Bool,
        accepts: @escaping @Sendable (EditorFieldValue) -> Bool = { _ in true },
        read: @escaping @Sendable (any Component) -> EditorFieldValue?,
        write: @escaping @Sendable (any Component, EditorFieldValue) -> (any Component)?
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isEditable = isEditable
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
        kind: EditorFieldKind,
        isEditable: Bool,
        accepts: @escaping @Sendable (EditorFieldValue) -> Bool = { _ in true },
        read: @escaping @Sendable (any Component) -> EditorFieldValue?,
        write: @escaping @Sendable (any Component, EditorFieldValue) -> (any Component)?,
        readPointer: (@Sendable (UnsafeRawPointer) -> EditorFieldValue?)? = nil,
        writePointer: (@Sendable (UnsafeMutableRawPointer, EditorFieldValue) -> Bool)? = nil
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isEditable = isEditable
        self.accepts = accepts
        self.read = read
        self.write = write
        unsafe self.readPointer = readPointer
        unsafe self.writePointer = writePointer
    }
}

public struct EditorComponentDescriptor: @unchecked Sendable {
    public var typeName: String
    public var displayName: String
    public var requiredComponentTypeNames: [String]
    public var fields: [EditorComponentFieldDescriptor]

    public init(
        typeName: String,
        displayName: String,
        requiredComponentTypeNames: [String],
        fields: [EditorComponentFieldDescriptor]
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
        fields: [EditorComponentFieldDescriptor]
    ) {
        self.init(
            typeName: String(reflecting: T.self),
            displayName: displayName,
            requiredComponentTypeNames: requiredComponentTypeNames,
            fields: fields
        )
    }

    public func readPayload(from component: any Component) -> [String: EditorFieldValue] {
        fields.reduce(into: [:]) { result, field in
            result[field.key] = field.read(component) ?? .null
        }
    }

    public func writing(_ value: EditorFieldValue, toField key: String, in component: any Component) -> (any Component)? {
        fields.first { $0.key == key }?.write(component, value)
    }

    @discardableResult
    public func write(_ value: EditorFieldValue, toField key: String, in world: World, entity: Entity.ID) -> Bool {
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

public protocol EditorEnumReflectable: CaseIterable, Sendable {
    var editorCaseName: String { get }
    static var editorCaseNames: [String] { get }
    static func editorCase(named name: String) -> Self?
}

extension EditorEnumReflectable {
    public var editorCaseName: String {
        String(describing: self)
    }

    public static var editorCaseNames: [String] {
        allCases.map(\.editorCaseName)
    }

    public static func editorCase(named name: String) -> Self? {
        allCases.first { $0.editorCaseName == name }
    }
}

public enum EditorComponentReflectionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: EditorComponentDescriptor] = [:]

    public static func register(_ descriptor: EditorComponentDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        unsafe descriptors[descriptor.typeName] = descriptor
    }

    public static func descriptor(named typeName: String) -> EditorComponentDescriptor? {
        lock.withLock { unsafe descriptors[typeName] }
    }

    public static func allDescriptors() -> [EditorComponentDescriptor] {
        lock.withLock { unsafe descriptors.values.sorted { $0.displayName < $1.displayName } }
    }
}

public enum EditorComponentReflection {
    public static func kind<T>(for _: T.Type) -> EditorFieldKind {
        .readOnly
    }

    public static func kind(for _: Bool.Type) -> EditorFieldKind { .bool }
    public static func kind(for _: Int.Type) -> EditorFieldKind { .int }
    public static func kind(for _: Float.Type) -> EditorFieldKind { .float }
    public static func kind(for _: Double.Type) -> EditorFieldKind { .float }
    public static func kind(for _: String.Type) -> EditorFieldKind { .string }
    public static func kind(for _: Vector2.Type) -> EditorFieldKind { .vector2 }
    public static func kind(for _: Vector3.Type) -> EditorFieldKind { .vector3 }
    public static func kind(for _: Vector4.Type) -> EditorFieldKind { .vector4 }
    public static func kind(for _: Quat.Type) -> EditorFieldKind { .vector4 }
    public static func kind(for _: Color.Type) -> EditorFieldKind { .color }
    public static func kind<T: EditorEnumReflectable>(for _: T.Type) -> EditorFieldKind { .enumeration(T.editorCaseNames) }

    public static func isEditable<T>(_: T.Type) -> Bool {
        false
    }

    public static func isEditable(_: Bool.Type) -> Bool { true }
    public static func isEditable(_: Int.Type) -> Bool { true }
    public static func isEditable(_: Float.Type) -> Bool { true }
    public static func isEditable(_: Double.Type) -> Bool { true }
    public static func isEditable(_: String.Type) -> Bool { true }
    public static func isEditable(_: Vector2.Type) -> Bool { true }
    public static func isEditable(_: Vector3.Type) -> Bool { true }
    public static func isEditable(_: Vector4.Type) -> Bool { true }
    public static func isEditable(_: Quat.Type) -> Bool { true }
    public static func isEditable(_: Color.Type) -> Bool { true }
    public static func isEditable<T: EditorEnumReflectable>(_: T.Type) -> Bool { true }

    public static func accepts<T>(_: EditorFieldValue, for _: T.Type) -> Bool { false }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Bool.Type) -> Bool { fieldValue.boolValue != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Int.Type) -> Bool { fieldValue.intValue != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Float.Type) -> Bool { fieldValue.validFloatValue != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Double.Type) -> Bool { fieldValue.doubleValue?.isFinite == true }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: String.Type) -> Bool {
        if case .string = fieldValue {
            return true
        }
        return false
    }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Vector2.Type) -> Bool { fieldValue.validFloatArray(count: 2) != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Vector3.Type) -> Bool { fieldValue.validFloatArray(count: 3) != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Vector4.Type) -> Bool { fieldValue.validFloatArray(count: 4) != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Quat.Type) -> Bool { fieldValue.validFloatArray(count: 4) != nil }
    public static func accepts(_ fieldValue: EditorFieldValue, for _: Color.Type) -> Bool { fieldValue.validColorComponents != nil }
    public static func accepts<T: EditorEnumReflectable>(_ fieldValue: EditorFieldValue, for _: T.Type) -> Bool {
        guard case let .string(string) = fieldValue else {
            return false
        }
        return T.editorCase(named: string) != nil
    }

    public static func read<T>(_ value: T) -> EditorFieldValue {
        .string(String(describing: value))
    }

    public static func read(_ value: Bool) -> EditorFieldValue { .bool(value) }
    public static func read(_ value: Int) -> EditorFieldValue { .int(value) }
    public static func read(_ value: Float) -> EditorFieldValue { .double(Double(value)) }
    public static func read(_ value: Double) -> EditorFieldValue { .double(value) }
    public static func read(_ value: String) -> EditorFieldValue { .string(value) }
    public static func read(_ value: Vector2) -> EditorFieldValue { .array([.double(Double(value.x)), .double(Double(value.y))]) }
    public static func read(_ value: Vector3) -> EditorFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z))]) }
    public static func read(_ value: Vector4) -> EditorFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z)), .double(Double(value.w))]) }
    public static func read(_ value: Quat) -> EditorFieldValue { .array([.double(Double(value.x)), .double(Double(value.y)), .double(Double(value.z)), .double(Double(value.w))]) }
    public static func read(_ value: Color) -> EditorFieldValue {
        .object([
            "red": .double(Double(value.red)),
            "green": .double(Double(value.green)),
            "blue": .double(Double(value.blue)),
            "alpha": .double(Double(value.alpha)),
        ])
    }
    public static func read<T: EditorEnumReflectable>(_ value: T) -> EditorFieldValue { .string(value.editorCaseName) }

    public static func write<T>(_: EditorFieldValue, to _: inout T) -> Bool {
        false
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Bool) -> Bool {
        guard let bool = fieldValue.boolValue else {
            return false
        }
        value = bool
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Int) -> Bool {
        guard let int = fieldValue.intValue else {
            return false
        }
        value = int
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Float) -> Bool {
        guard let float = fieldValue.validFloatValue else {
            return false
        }
        value = float
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Double) -> Bool {
        guard let double = fieldValue.doubleValue, double.isFinite else {
            return false
        }
        value = double
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout String) -> Bool {
        guard case let .string(string) = fieldValue else {
            return false
        }
        value = string
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Vector2) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 2) else {
            return false
        }
        value = Vector2(components[0], components[1])
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Vector3) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 3) else {
            return false
        }
        value = Vector3(components[0], components[1], components[2])
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Vector4) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 4) else {
            return false
        }
        value = Vector4(components[0], components[1], components[2], components[3])
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Quat) -> Bool {
        guard let components = fieldValue.validFloatArray(count: 4) else {
            return false
        }
        value = Quat(x: components[0], y: components[1], z: components[2], w: components[3])
        return true
    }

    public static func write(_ fieldValue: EditorFieldValue, to value: inout Color) -> Bool {
        guard let components = fieldValue.validColorComponents else {
            return false
        }
        value = Color(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        return true
    }

    public static func write<T: EditorEnumReflectable>(_ fieldValue: EditorFieldValue, to value: inout T) -> Bool {
        guard
            case let .string(string) = fieldValue,
            let enumValue = T.editorCase(named: string)
        else {
            return false
        }
        value = enumValue
        return true
    }
}

extension EditorFieldValue {
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
