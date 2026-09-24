import Gravity

/// Native bridge types with callback-borrowed state opt into this policy.
/// The AdaScript spelling is `@nonsendable` on a script-owned type declaration.
protocol AdaScriptNonSendableBridge {}

/// Native handles whose own synchronization and lifetime permit suspension.
protocol AdaScriptSuspensionSafeBridge {}

/// The VM serializes registration and validation through AdaScriptRuntimeCoordinator.
final class AdaScriptSuspensionPolicy: @unchecked Sendable {
    private struct Matcher {
        let name: String
        let matches: (GSValue) -> Bool
    }

    private var borrowed: [Matcher] = []
    private var safeHandles: [Matcher] = []
    private let scriptNonSendableTypes: Set<String>

    init(scriptNonSendableTypes: Set<String>) {
        self.scriptNonSendableTypes = scriptNonSendableTypes
    }

    func bindBorrowed<T: GSExportable & AdaScriptNonSendableBridge>(
        _ type: T.Type,
        to virtualMachine: GravityVirtualMachine
    ) throws {
        try virtualMachine.bindClass(with: type)
        borrowed.append(Matcher(name: type.runtimeName, matches: { $0.toObjectOf(type) != nil }))
    }

    func bindSafe<T: GSExportable & AdaScriptSuspensionSafeBridge>(
        _ type: T.Type,
        to virtualMachine: GravityVirtualMachine
    ) throws {
        try virtualMachine.bindClass(with: type)
        safeHandles.append(Matcher(name: type.runtimeName, matches: { $0.toObjectOf(type) != nil }))
    }

    func validate(_ value: GSValue) -> String? {
        violation(in: value, depth: 0)
    }

    private func violation(in value: GSValue, depth: Int) -> String? {
        guard depth < 16 else {
            return "capture nesting exceeds the suspension limit"
        }
        if value.isNull || value.isUndefined || value.isBool || value.isInteger || value.isDouble || value.isString {
            return nil
        }
        if value.isList {
            for element in value.toList {
                if let reason = violation(in: element, depth: depth + 1) {
                    return reason
                }
            }
            return nil
        }
        if value.isMap {
            return "map captures require a detached value"
        }
        if value.isFiber || value.isClosure {
            return "VM closures and fibers cannot cross a suspension boundary"
        }
        if let type = borrowed.first(where: { $0.matches(value) }) {
            return "@nonsendable native type '\(type.name)' cannot cross a suspension boundary"
        }
        if value.isInstance || value.isStruct {
            let className = value.toClass.name
            let declaredName = scriptNonSendableTypes.contains(className) ? className : value.name
            if scriptNonSendableTypes.contains(declaredName) {
                return "@nonsendable type '\(declaredName)' cannot cross a suspension boundary"
            }
        }
        if value.xData != nil {
            if safeHandles.contains(where: { $0.matches(value) }) {
                return nil
            }
            return "native value '\(value.name)' has no suspension policy"
        }
        return nil
    }
}
