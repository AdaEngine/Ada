@_spi(Scripting) import AdaECS
import Gravity

struct AdaScriptLinkedComponentConstructor: Sendable {
    let constructor: RegisteredRuntimeComponentConstructor
    let index: Int

}

enum AdaScriptComponentRuntime {
    static func linkedConstructors() -> [AdaScriptLinkedComponentConstructor] {
        RuntimeTypeRegistry.registeredRuntimeComponentConstructors()
            .enumerated()
            .map { AdaScriptLinkedComponentConstructor(constructor: $0.element, index: $0.offset) }
    }

    static func prelude(
        constructors: [AdaScriptLinkedComponentConstructor]
    ) -> String {
        let constructorDeclarations = constructors.compactMap { linkedConstructor -> String? in
            let constructor = linkedConstructor.constructor
            guard
                isIdentifier(constructor.name),
                constructor.parameters.allSatisfy({ isIdentifier($0.name) })
            else {
                return nil
            }
            let parameters = constructor.parameters
                .map(\.name)
                .joined(separator: ", ")
            let arguments = constructor.parameters
                .map(\.name)
                .joined(separator: ", ")
            return """
            func \(constructor.name)(\(parameters)) {
                return __adaComponentFactory.make(\(linkedConstructor.index), [\(arguments)]);
            }
            """
        }
        return ([
            "extern var __adaComponentFactory;",
            """
            class __AdaVector3Factory {
                var ZERO {
                    get { return [0.0, 0.0, 0.0]; }
                };

                func exec(x, y, z) {
                    return [x, y, z];
                }
            }
            var Vector3 = __AdaVector3Factory();
            """,
        ] + constructorDeclarations).joined(separator: "\n") + "\n"
    }

    static func bind(
        to virtualMachine: GravityVirtualMachine,
        constructors: [AdaScriptLinkedComponentConstructor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) throws {
        try virtualMachine.bindClass(with: AnnotatedGravityComponentValue.self)
        try virtualMachine.bindClass(with: AnnotatedGravityComponentFactory.self)
        virtualMachine.setValue(
            AnnotatedGravityComponentFactory.make(
                constructors: constructors.map(\.constructor),
                reportDiagnostic: reportDiagnostic
            ),
            forKey: "__adaComponentFactory"
        )
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

@GSExportable("AdaComponentValue")
final class AnnotatedGravityComponentValue: @unchecked Sendable {
    @GSExportableIgnore
    private var component: (any Component)?

    @GSExportableIgnore
    init(component: consuming any Component) {
        self.component = component
    }

    @GSExportableIgnore
    init() {
        self.component = nil
    }

    @GSExportableIgnore
    func takeComponent() -> (any Component)? {
        let component = component
        self.component = nil
        return component
    }
}

@GSExportable("AdaComponentFactory")
final class AnnotatedGravityComponentFactory: @unchecked Sendable {
    @GSExportableIgnore
    private let constructors: [RegisteredRuntimeComponentConstructor]

    @GSExportableIgnore
    private let reportDiagnostic: @Sendable (String) -> Void

    @GSExportableIgnore
    static func make(
        constructors: [RegisteredRuntimeComponentConstructor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AnnotatedGravityComponentFactory {
        AnnotatedGravityComponentFactory(
            constructors: constructors,
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        constructors: [RegisteredRuntimeComponentConstructor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.constructors = constructors
        self.reportDiagnostic = reportDiagnostic
    }

    func make(_ constructorIndex: Int, _ argumentValues: GSValue) -> AnnotatedGravityComponentValue {
        guard constructors.indices.contains(constructorIndex) else {
            reportDiagnostic("AdaScript component constructor index \(constructorIndex) is not linked")
            return AnnotatedGravityComponentValue()
        }
        guard argumentValues.isList else {
            reportDiagnostic("AdaScript component constructor arguments must be a list")
            return AnnotatedGravityComponentValue()
        }

        var arguments: [ReflectedFieldValue?] = []
        arguments.reserveCapacity(argumentValues.toList.count)
        for value in argumentValues.toList {
            if value.isNull || value.isUndefined {
                arguments.append(nil)
                continue
            }
            guard let fieldValue = AnnotatedGravityValueBridge.makeReflectedFieldValue(value) else {
                reportDiagnostic("AdaScript component constructor received an unsupported value")
                return AnnotatedGravityComponentValue()
            }
            arguments.append(fieldValue)
        }

        do {
            return AnnotatedGravityComponentValue(
                component: try constructors[constructorIndex].construct(arguments: arguments)
            )
        } catch {
            reportDiagnostic(String(describing: error))
            return AnnotatedGravityComponentValue()
        }
    }
}
