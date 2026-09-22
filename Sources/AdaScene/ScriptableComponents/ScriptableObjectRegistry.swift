import AdaECS
import Foundation

public enum ScriptableObjectCodingError: Error, Equatable, Sendable, CustomStringConvertible {
    case duplicateAlias(String)
    case duplicateIdentifier(String)
    case invalidVersion(Int, type: String)
    case unknownType(String)
    case unregisteredRuntimeType(String)
    case unsupportedVersion(encoded: Int, current: Int, type: String)

    public var description: String {
        switch self {
        case let .duplicateAlias(alias):
            "Duplicate scriptable object alias '\(alias)'"
        case let .duplicateIdentifier(identifier):
            "Duplicate scriptable object identifier '\(identifier)'"
        case let .invalidVersion(version, type):
            "Invalid scriptable object version \(version) for '\(type)'"
        case let .unknownType(identifier):
            "Unknown scriptable object type '\(identifier)'"
        case let .unregisteredRuntimeType(type):
            "Unregistered scriptable object runtime type '\(type)'"
        case let .unsupportedVersion(encoded, current, type):
            "Scriptable object '\(type)' uses version \(encoded), but this runtime supports \(current)"
        }
    }
}

public struct ScriptableObjectDescriptor: Sendable {
    public let aliases: [String]
    public let declaredAccess: SystemAccessSet
    public let exportedFields: [String: ReflectedFieldValue]
    public let identifier: String
    public let requiredComponents: [ComponentId]
    public let version: Int

    package let decode: @Sendable (Decoder, Int) throws -> ScriptableObject
    package let make: @Sendable () -> ScriptableObject
    package let runtimeType: ObjectIdentifier?

    public init(
        identifier: String,
        version: Int,
        aliases: [String] = [],
        declaredAccess: SystemAccessSet = SystemAccessSet(),
        exportedFields: [String: ReflectedFieldValue] = [:],
        requiredComponents: [ComponentId] = [],
        runtimeType: ObjectIdentifier? = nil,
        make: @escaping @Sendable () -> ScriptableObject,
        decode: @escaping @Sendable (Decoder, Int) throws -> ScriptableObject
    ) {
        self.aliases = aliases
        self.declaredAccess = declaredAccess
        self.exportedFields = exportedFields
        self.decode = decode
        self.identifier = identifier
        self.make = make
        self.requiredComponents = requiredComponents
        self.runtimeType = runtimeType
        self.version = version
    }
}

public enum ScriptableObjectRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptorsByName: [String: ScriptableObjectDescriptor] = [:]
    nonisolated(unsafe) private static var identifiersByType: [ObjectIdentifier: String] = [:]

    @MainActor
    public static func register<T: ScriptableObject>(
        _ type: T.Type,
        identifier: String,
        version: Int = 1,
        aliases: [String] = [],
        declaredAccess: SystemAccessSet = SystemAccessSet(),
        exportedFields: [String: ReflectedFieldValue] = [:],
        requiredComponents: [any Component.Type] = []
    ) throws {
        try register(
            ScriptableObjectDescriptor(
                identifier: identifier,
                version: version,
                aliases: aliases,
                declaredAccess: declaredAccess,
                exportedFields: exportedFields,
                requiredComponents: requiredComponents.map { $0.identifier },
                runtimeType: ObjectIdentifier(type),
                make: { T() },
                decode: { decoder, encodedVersion in
                    let object = try T(from: decoder)
                    object.encodedSchemaVersion = encodedVersion
                    return object
                }
            )
        )
    }

    @MainActor
    public static func register(_ descriptor: ScriptableObjectDescriptor) throws {
        guard descriptor.version > 0 else {
            throw ScriptableObjectCodingError.invalidVersion(descriptor.version, type: descriptor.identifier)
        }

        try lock.withLock {
            if unsafe descriptorsByName[descriptor.identifier] != nil {
                throw ScriptableObjectCodingError.duplicateIdentifier(descriptor.identifier)
            }
            for alias in descriptor.aliases where unsafe descriptorsByName[alias] != nil {
                throw ScriptableObjectCodingError.duplicateAlias(alias)
            }
            unsafe descriptorsByName[descriptor.identifier] = descriptor
            for alias in descriptor.aliases {
                unsafe descriptorsByName[alias] = descriptor
            }
            if let runtimeType = descriptor.runtimeType {
                unsafe identifiersByType[runtimeType] = descriptor.identifier
            }
        }
    }

    public static func descriptor(named name: String) -> ScriptableObjectDescriptor? {
        lock.withLock { unsafe descriptorsByName[name] }
    }

    public static func descriptor(for object: ScriptableObject) -> ScriptableObjectDescriptor? {
        lock.withLock {
            if let explicitIdentifier = object.explicitTypeIdentifier,
                let descriptor = unsafe descriptorsByName[explicitIdentifier] {
                return descriptor
            }
            guard let identifier = unsafe identifiersByType[ObjectIdentifier(type(of: object))] else {
                return nil
            }
            return unsafe descriptorsByName[identifier]
        }
    }

    public static func make(named name: String) throws -> ScriptableObject {
        guard let descriptor = descriptor(named: name) else {
            throw ScriptableObjectCodingError.unknownType(name)
        }
        return descriptor.make()
    }

    public static func combinedDeclaredAccess() -> SystemAccessSet {
        lock.withLock {
            var access = SystemAccessSet()
            var identifiers = Set<String>()
            for descriptor in unsafe descriptorsByName.values where identifiers.insert(descriptor.identifier).inserted {
                access.formUnion(descriptor.declaredAccess)
            }
            return access
        }
    }
}

struct ScriptableObjectEnvelope: Codable {
    let script: ScriptableObject

    private enum CodingKeys: String, CodingKey {
        case payload
        case type
        case version
    }

    init(script: ScriptableObject) {
        self.script = script
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let version = try container.decode(Int.self, forKey: .version)
        guard let descriptor = ScriptableObjectRegistry.descriptor(named: type) else {
            throw ScriptableObjectCodingError.unknownType(type)
        }
        guard version <= descriptor.version else {
            throw ScriptableObjectCodingError.unsupportedVersion(
                encoded: version,
                current: descriptor.version,
                type: descriptor.identifier
            )
        }
        script = try descriptor.decode(container.superDecoder(forKey: .payload), version)
    }

    func encode(to encoder: Encoder) throws {
        guard let descriptor = ScriptableObjectRegistry.descriptor(for: script) else {
            throw ScriptableObjectCodingError.unregisteredRuntimeType(String(reflecting: type(of: script)))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(descriptor.identifier, forKey: .type)
        try container.encode(descriptor.version, forKey: .version)
        try script.encode(to: container.superEncoder(forKey: .payload))
    }
}
