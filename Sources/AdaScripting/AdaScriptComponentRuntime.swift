@_spi(Scripting) import AdaECS
import AdaScriptCompilerCore
import Gravity

struct AdaScriptLinkedComponentConstructor: Sendable {
    let constructor: RegisteredRuntimeComponentConstructor
    let index: Int

}

enum AdaScriptComponentRuntime {
    static func runtimeDescriptors(
        schemas: [AdaScriptDataSchema]
    ) -> [RuntimeComponentDescriptor] {
        schemas.compactMap { schema in
            guard schema.kind == .component else { return nil }
            return RuntimeComponentDescriptor(
                stableID: schema.id,
                name: schema.name,
                fieldNames: schema.fields.map(\.name),
                defaultValues: schema.fields.map { reflectedValue($0.defaultValue) }
            )
        }
    }

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
        runtimeDescriptors: [RuntimeComponentDescriptor] = [],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) throws {
        try virtualMachine.bindClass(with: AnnotatedGravityComponentValue.self)
        try virtualMachine.bindClass(with: AnnotatedGravityComponentFactory.self)
        virtualMachine.setValue(
            AnnotatedGravityComponentFactory.make(
                constructors: constructors.map(\.constructor),
                runtimeDescriptors: runtimeDescriptors,
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

    private static func reflectedValue(_ value: AdaScriptSchemaField.Value) -> ReflectedFieldValue {
        switch value {
        case let .bool(value): .bool(value)
        case let .double(value): .double(value)
        case let .int(value): .int(Int(value))
        case let .string(value): .string(value)
        }
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
    private let constructorsByName: [String: RegisteredRuntimeComponentConstructor]

    @GSExportableIgnore
    private let runtimeDescriptorsByName: [String: RuntimeComponentDescriptor]

    @GSExportableIgnore
    private let reportDiagnostic: @Sendable (String) -> Void

    @GSExportableIgnore
    static func make(
        constructors: [RegisteredRuntimeComponentConstructor],
        runtimeDescriptors: [RuntimeComponentDescriptor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) -> AnnotatedGravityComponentFactory {
        AnnotatedGravityComponentFactory(
            constructors: constructors,
            runtimeDescriptors: runtimeDescriptors,
            reportDiagnostic: reportDiagnostic
        )
    }

    private init(
        constructors: [RegisteredRuntimeComponentConstructor],
        runtimeDescriptors: [RuntimeComponentDescriptor],
        reportDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.constructors = constructors
        self.constructorsByName = Dictionary(uniqueKeysWithValues: constructors.map { ($0.name, $0) })
        self.runtimeDescriptorsByName = Dictionary(
            uniqueKeysWithValues: runtimeDescriptors.flatMap { descriptor in
                [(descriptor.name, descriptor), (descriptor.stableID, descriptor)]
            }
        )
        self.reportDiagnostic = reportDiagnostic
    }

    func make(_ constructorIndex: Int, _ argumentValues: GSValue) -> AnnotatedGravityComponentValue {
        guard constructors.indices.contains(constructorIndex) else {
            reportDiagnostic("AdaScript component constructor index \(constructorIndex) is not linked")
            return AnnotatedGravityComponentValue()
        }
        guard let arguments = arguments(from: argumentValues) else { return AnnotatedGravityComponentValue() }

        do {
            return AnnotatedGravityComponentValue(
                component: try constructors[constructorIndex].construct(arguments: arguments)
            )
        } catch {
            reportDiagnostic(String(describing: error))
            return AnnotatedGravityComponentValue()
        }
    }

    func makeNamed(_ name: String, _ argumentValues: GSValue) -> AnnotatedGravityComponentValue {
        guard let arguments = arguments(from: argumentValues) else { return AnnotatedGravityComponentValue() }
        if let constructor = constructorsByName[name] {
            do {
                return AnnotatedGravityComponentValue(component: try constructor.construct(arguments: arguments))
            } catch {
                reportDiagnostic(String(describing: error))
                return AnnotatedGravityComponentValue()
            }
        }
        guard let descriptor = runtimeDescriptorsByName[name] else {
            reportDiagnostic("Unknown AdaScript component constructor '\(name)'")
            return AnnotatedGravityComponentValue()
        }
        guard arguments.count == descriptor.defaultValues.count else {
            reportDiagnostic("AdaScript component '\(name)' expected \(descriptor.defaultValues.count) arguments")
            return AnnotatedGravityComponentValue()
        }
        var values = descriptor.defaultValues
        for index in arguments.indices {
            if let value = arguments[index] {
                guard descriptor.fields[index].accepts(value) else {
                    reportDiagnostic("AdaScript component '\(name)' received an invalid value for '\(descriptor.fields[index].key)'")
                    return AnnotatedGravityComponentValue()
                }
                values[index] = value
            }
        }
        return AnnotatedGravityComponentValue(
            component: RuntimeComponentPayload(
                componentID: descriptor.componentID,
                stableID: descriptor.stableID,
                values: values
            )
        )
    }

    private func arguments(from argumentValues: GSValue) -> [ReflectedFieldValue?]? {
        guard argumentValues.isList else {
            reportDiagnostic("AdaScript component constructor arguments must be a list")
            return nil
        }
        var arguments: [ReflectedFieldValue?] = []
        arguments.reserveCapacity(argumentValues.toList.count)
        for value in argumentValues.toList {
            if value.isNull || value.isUndefined {
                arguments.append(nil)
            } else if let fieldValue = AnnotatedGravityValueBridge.makeReflectedFieldValue(value) {
                arguments.append(fieldValue)
            } else {
                reportDiagnostic("AdaScript component constructor received an unsupported value")
                return nil
            }
        }
        return arguments
    }
}
