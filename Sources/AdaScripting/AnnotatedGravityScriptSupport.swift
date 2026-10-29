@_spi(Scripting) import AdaECS
import AdaUtils
@_spi(Internal) import Gravity

@GSExportable("AdaSystemContext")
final class AnnotatedGravitySystemContext: @unchecked Sendable, AdaScriptNonSendableBridge {
    let deltaTime: Double
    let world: AnnotatedGravityWorldContext

    @GSExportableIgnore
    static func make(deltaTime: Double, world: AnnotatedGravityWorldContext) -> AnnotatedGravitySystemContext {
        AnnotatedGravitySystemContext(deltaTime: deltaTime, world: world)
    }

    private init(deltaTime: Double, world: AnnotatedGravityWorldContext) {
        self.deltaTime = deltaTime
        self.world = world
    }
}

final class AnnotatedGravityRuntimeDelegate: GravityVirtualMachineDelegate, @unchecked Sendable {
    private(set) var errors: [String] = []
    private let pathsByFileID: [UInt32: String]
    private let sourcesByPath: [String: ResolvedGravityScriptModule.Source]

    init(module: ResolvedGravityScriptModule, sourcesByPath: [String: ResolvedGravityScriptModule.Source]? = nil) {
        self.pathsByFileID = module.pathsByFileID
        self.sourcesByPath = sourcesByPath ?? module.sourcesByPath
    }

    func append(_ message: String) {
        errors.append(message)
        RuntimeLogStore.shared.append(level: "error", label: "AdaScript", message: message)
    }

    func virtualMachineLoadFile(
        _: GravityVirtualMachine,
        file: String,
        fileId: inout UInt32,
        isStatic: inout Bool
    ) -> String? {
        guard let source = sourcesByPath[file] else {
            return nil
        }
        fileId = source.fileID
        isStatic = true
        return source.source
    }

    func virtualMachine(
        _: GravityVirtualMachine,
        didErrorWith message: String,
        errorType _: error_type_t,
        errorDescription: error_desc_t
    ) {
        if let path = pathsByFileID[errorDescription.fileid] {
            append("\(path):\(errorDescription.lineno):\(errorDescription.colno): \(message)")
        } else {
            append(message)
        }
    }

    func virtualMachineDidReciveLog(_: GravityVirtualMachine, message: String) {
        RuntimeLogStore.shared.append(level: "info", label: "AdaScript", message: message)
    }
    func virtualMachineDidClearLog(_: GravityVirtualMachine) {}
    func virtualMachineBridgeEquals(_: GravityVirtualMachine, lhsValue _: GSValue, rhsValue _: GSValue) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didExecuteIn _: GSValue, arguments _: [GSValue], argumentsCount _: Int16, vIndex _: UInt32) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didSetValue _: GSValue, in _: GSValue, forKey _: String) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didGetValueFrom _: GSValue, forKey _: String) throws -> GSValue? { nil }

    func virtualMachine(
        _: GravityVirtualMachine,
        didSetUndefValue value: GSValue,
        in target: GSValue,
        forKey key: String
    ) -> Bool {
        guard let component = target.toObjectOf(AnnotatedGravityComponentView.self) else {
            if let resource = target.toObjectOf(AnnotatedGravityResourceView.self) {
                return resource.set(key, value)
            }
            if let component = target.toObjectOf(GravityAttachedComponentView.self) {
                return component.set(key, value)
            }
            if let resource = target.toObjectOf(GravityAttachedResourceView.self) {
                return resource.set(key, value)
            }
            return false
        }
        return component.set(key, value)
    }

    func virtualMachine(
        _ virtualMachine: GravityVirtualMachine,
        didGetUndefValueFrom target: GSValue,
        forKey key: String
    ) throws -> GSValue? {
        if let row = target.toObjectOf(AnnotatedGravityQueryRow.self),
            let component = row.componentValue(named: key) {
            return component
        }
        if let component = target.toObjectOf(AnnotatedGravityComponentView.self) {
            return component.get(key)
        }
        if let resource = target.toObjectOf(AnnotatedGravityResourceView.self) {
            return resource.get(key)
        }
        if let value = target.toObjectOf(AdaScriptNetworkValueBridge.self) {
            return value.get(key)
        }
        if let component = target.toObjectOf(GravityAttachedComponentView.self) {
            return component.get(key)
        }
        if let resource = target.toObjectOf(GravityAttachedResourceView.self) {
            return resource.get(key)
        }
        return nil
    }

    func virtualMachine(_: GravityVirtualMachine, didRequestStringWith _: UInt32) -> String { "" }
}

enum AnnotatedGravityValueBridge {
    static func makeGravityValue(_ value: ReflectedFieldValue, virtualMachine: GravityVirtualMachine) -> GSValue {
        switch value {
        case .null: GSValue(nullIn: virtualMachine)
        case let .bool(value): GSValue(boolean: value, in: virtualMachine)
        case let .int(value): GSValue(integer: value, in: virtualMachine)
        case let .double(value): GSValue(double: value, in: virtualMachine)
        case let .string(value): GSValue(string: value, in: virtualMachine)
        case let .array(values):
            makeArray(values, virtualMachine: virtualMachine)
        case let .object(values):
            makeArray(["red", "green", "blue", "alpha"].compactMap { values[$0] }, virtualMachine: virtualMachine)
        }
    }

    private static func makeArray(_ values: [ReflectedFieldValue], virtualMachine: GravityVirtualMachine) -> GSValue {
        var scalars: [gravity_value_t] = []
        scalars.reserveCapacity(values.count)
        for value in values {
            switch value {
            case .null: scalars.append(gravity_value_from_null())
            case let .bool(value): scalars.append(gravity_value_from_bool(value))
            case let .int(value): scalars.append(gravity_value_from_int(gravity_int_t(value)))
            case let .double(value): scalars.append(gravity_value_from_float(value))
            default:
                // Strings and nested lists retain their existing construction path.
                return GSValue(newArrayIn: virtualMachine, items: values.map { makeGravityValue($0, virtualMachine: virtualMachine) as Any })
            }
        }
        return virtualMachine.makeScalarList(scalars)
    }

    static func makeReflectedFieldValue(_ value: GSValue) -> ReflectedFieldValue? {
        makeReflectedFieldValue(value.value)
    }

    private static func makeReflectedFieldValue(_ value: gravity_value_t) -> ReflectedFieldValue? {
        if gravity_value_isa_null(value) || gravity_value_isa_undefined(value) {
            return .null
        }
        if gravity_value_isa_bool(value) {
            return .bool(gravity_cast_value_as_bool(value))
        }
        if gravity_value_isa_int(value) {
            guard let integer = Int(exactly: value.n) else {
                return nil
            }
            return .int(integer)
        }
        if gravity_value_isa_float(value) {
            return .double(value.f)
        }
        if gravity_value_isa_string(value) {
            return .string(String(cString: gravity_cast_value_as_cString(value)))
        }
        if gravity_value_isa_list(value) {
            let count = gravity_list_count(value)
            var result: [ReflectedFieldValue] = []
            result.reserveCapacity(Int(count))
            for index in 0..<count {
                let item = gravity_list_get_value_at_index(value, Int32(index))
                guard let converted = makeReflectedFieldValue(item) else {
                    return nil
                }
                result.append(converted)
            }
            return .array(result)
        }
        return nil
    }
}

extension GravityAnnotation {
    func stringArgument(label: String) -> String? {
        arguments.first { $0.label == label }?.value.stringValue
    }

    func identifierListArgument(label: String) -> [String] {
        guard let value = arguments.first(where: { $0.label == label })?.value else {
            return []
        }
        switch value {
        case let .identifier(value):
            return [value]
        case let .list(values):
            return values.compactMap(\.identifierValue)
        default:
            return []
        }
    }
}

extension GravityAnnotation.Value {
    var identifierValue: String? {
        guard case let .identifier(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}
