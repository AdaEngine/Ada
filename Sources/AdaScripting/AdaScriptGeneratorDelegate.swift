import Gravity

/// A generator VM has no ECS or scene access. Its delegate only resolves module sources and collects diagnostics.
/// The owning runner confines this mutable object to its synchronous VM call under the runtime lock.
final class AdaScriptGeneratorDelegate: GravityVirtualMachineDelegate {
    private(set) var errors: [String] = []
    private let paths: [UInt32: String]
    private let sources: [String: ResolvedGravityScriptModule.Source]

    init(module: ResolvedGravityScriptModule, sourcesByPath: [String: ResolvedGravityScriptModule.Source]) {
        paths = module.pathsByFileID
        sources = sourcesByPath
    }

    func virtualMachineLoadFile(_: GravityVirtualMachine, file: String, fileId: inout UInt32, isStatic: inout Bool) -> String? {
        guard let source = sources[file] else { return nil }
        fileId = source.fileID
        isStatic = true
        return source.source
    }

    func virtualMachine(_: GravityVirtualMachine, didErrorWith message: String, errorType _: error_type_t, errorDescription: error_desc_t) {
        if let path = paths[errorDescription.fileid] {
            errors.append("\(path):\(errorDescription.lineno):\(errorDescription.colno): \(message)")
        } else { errors.append(message) }
    }

    func virtualMachineDidReciveLog(_: GravityVirtualMachine, message _: String) {}
    func virtualMachineDidClearLog(_: GravityVirtualMachine) {}
    func virtualMachineBridgeEquals(_: GravityVirtualMachine, lhsValue _: GSValue, rhsValue _: GSValue) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didExecuteIn _: GSValue, arguments _: [GSValue], argumentsCount _: Int16, vIndex _: UInt32) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didSetValue _: GSValue, in _: GSValue, forKey _: String) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didGetValueFrom _: GSValue, forKey _: String) throws -> GSValue? { nil }
    func virtualMachine(_: GravityVirtualMachine, didSetUndefValue _: GSValue, in _: GSValue, forKey _: String) -> Bool { false }
    func virtualMachine(_: GravityVirtualMachine, didGetUndefValueFrom _: GSValue, forKey _: String) throws -> GSValue? { nil }
    func virtualMachine(_: GravityVirtualMachine, didRequestStringWith _: UInt32) -> String { "" }
}
