@_spi(Scripting) import AdaECS
import AdaUtils
import Gravity

@GSExportable("AdaSystemContext")
final class AnnotatedGravitySystemContext: @unchecked Sendable {
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

    init(module: ResolvedGravityScriptModule) {
        self.pathsByFileID = module.pathsByFileID
        self.sourcesByPath = module.sourcesByPath
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
            let component = row.component(named: key) {
            return GSValue(object: component, in: virtualMachine)
        }
        if let component = target.toObjectOf(AnnotatedGravityComponentView.self) {
            return component.get(key)
        }
        if let resource = target.toObjectOf(AnnotatedGravityResourceView.self) {
            return resource.get(key)
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
    static func makeGravityValue(_ value: EditorFieldValue, virtualMachine: GravityVirtualMachine) -> GSValue {
        switch value {
        case .null: GSValue(nullIn: virtualMachine)
        case let .bool(value): GSValue(boolean: value, in: virtualMachine)
        case let .int(value): GSValue(integer: value, in: virtualMachine)
        case let .double(value): GSValue(double: value, in: virtualMachine)
        case let .string(value): GSValue(string: value, in: virtualMachine)
        case let .array(values):
            GSValue(newArrayIn: virtualMachine, items: values.map { makeGravityValue($0, virtualMachine: virtualMachine) as Any })
        case let .object(values):
            GSValue(
                newArrayIn: virtualMachine,
                items: ["red", "green", "blue", "alpha"].compactMap { values[$0] }
                    .map {
                        makeGravityValue($0, virtualMachine: virtualMachine) as Any
                    }
            )
        }
    }

    static func makeEditorFieldValue(_ value: GSValue) -> EditorFieldValue? {
        if value.isNull || value.isUndefined {
            return .null
        }
        if value.isBool {
            return .bool(value.toBoolean)
        }
        if value.isInteger {
            guard let integer = Int(exactly: value.toInteger) else {
                return nil
            }
            return .int(integer)
        }
        if value.isDouble {
            return .double(value.toDouble)
        }
        if value.isString {
            return .string(value.toString)
        }
        if value.isList {
            var result: [EditorFieldValue] = []
            for item in value.toList {
                guard let converted = makeEditorFieldValue(item) else {
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
