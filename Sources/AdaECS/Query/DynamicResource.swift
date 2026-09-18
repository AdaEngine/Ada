import AdaUtils
import Foundation

public struct RuntimeResourceDescriptor: Sendable {
    public let fields: [EditorComponentFieldDescriptor]
    public let typeIdentifier: ObjectIdentifier

    public init<T: Resource>(type: T.Type, fields: [EditorComponentFieldDescriptor]) {
        self.fields = fields
        self.typeIdentifier = ObjectIdentifier(type)
    }
}

public enum RuntimeResourceReflectionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [ObjectIdentifier: RuntimeResourceDescriptor] = [:]

    public static func register<T: Resource>(_ type: T.Type, fields: [EditorComponentFieldDescriptor]) {
        lock.withLock {
            unsafe descriptors[ObjectIdentifier(type)] = RuntimeResourceDescriptor(type: type, fields: fields)
        }
    }

    public static func descriptor(for type: any Resource.Type) -> RuntimeResourceDescriptor? {
        lock.withLock { unsafe descriptors[ObjectIdentifier(type)] }
    }
}

/// A resource parameter whose Swift type is resolved from Ada Script metadata.
@_spi(Scripting)
@propertyWrapper
@safe
public final class DynamicResource: @unchecked Sendable {
    public var wrappedValue: DynamicResource { self }

    public let access: SystemAccessSet
    public let isOptional: Bool

    private let resourceType: any Resource.Type
    private var changedTick: UnsafeBox<Tick>?
    private var currentTick = Tick(value: 0)
    private var pointer: UnsafeMutableRawPointer?

    public init(resourceType: any Resource.Type, isOptional: Bool, writable: Bool) {
        self.resourceType = resourceType
        self.isOptional = isOptional
        var access = SystemAccessSet()
        if writable {
            access.addResourceWrite(ObjectIdentifier(resourceType))
        } else {
            access.addResourceRead(ObjectIdentifier(resourceType))
        }
        self.access = access
    }

    // Runtime metadata is required and cannot be recovered from World alone.
    // swiftlint:disable:next unavailable_function
    public init(from _: World) {
        fatalError("DynamicResource must be initialized with a runtime resource plan")
    }

    public var isAvailable: Bool { unsafe pointer != nil }

    public func read(field: EditorComponentFieldDescriptor) -> EditorFieldValue? {
        guard let pointer = unsafe pointer, let readPointer = unsafe field.readPointer else {
            return nil
        }
        return unsafe readPointer(UnsafeRawPointer(pointer))
    }

    @discardableResult
    public func write(field: EditorComponentFieldDescriptor, value: EditorFieldValue) -> Bool {
        guard
            field.accepts(value), let pointer = unsafe pointer, let writePointer = unsafe field.writePointer,
            unsafe writePointer(pointer, value)
        else {
            return false
        }
        changedTick?.wrappedValue = currentTick
        return true
    }
}

extension DynamicResource: SystemParameter {
    public func update(from world: World) {
        guard let data = world.resources.getResourceData(for: resourceType) else {
            unsafe pointer = nil
            changedTick = nil
            return
        }
        unsafe pointer = data.pointer.buffer.pointer.baseAddress
        changedTick = data.changedTick
        currentTick = world.currentTick
    }

    public func finish(_: World) {
        unsafe pointer = nil
        changedTick = nil
    }
}
