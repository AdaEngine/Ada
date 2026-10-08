#if canImport(GravityAOT)
import AdaECS
import AdaScriptCompilerCore
import Gravity
import GravityAOT

/// Scalar resource state defined by native module schemas, keyed by stable resource ID.
/// ResMut access to this carrier conservatively serializes writes to compiled resources.
public struct AdaScriptNativeResources: Resource {
    public var values: [String: [String: ReflectedFieldValue]]
    public init(values: [String: [String: ReflectedFieldValue]] = [:]) { self.values = values }
}

struct NativeResourceSchema: Sendable {
    let name: String
    let identifier: String
    let defaults: [String: ReflectedFieldValue]
    let autoInsert: Bool
}

extension NativeAttribute {
    func requireString(_ label: String, default fallback: String? = nil) throws -> String {
        if let value = argument(label), case .string(let string) = value, !string.isEmpty {
            return string
        }
        if argument(label) == nil, let fallback {
            return fallback
        }
        throw AdaScriptError.invalidManifest("@\(name) requires \(label): a nonempty string")
    }
    func boolean(_ label: String, default fallback: Bool = false) throws -> Bool {
        guard let value = argument(label) else {
            return fallback
        }
        guard case .boolean(let result) = value else { throw AdaScriptError.invalidManifest("@\(name) \(label) must be Bool") }
        return result
    }
    func bindingType() throws -> String {
        guard positional.count == 1, case .identifier(let name) = positional[0] else {
            throw AdaScriptError.invalidManifest("@\(name) requires exactly one type identifier")
        }
        return name
    }
}

extension NativeDeclaration {
    var gravityAnnotations: [GravityAnnotation] {
        attributes.map { a in
            let kind: GravityAnnotation.Target.Kind =
                switch self.kind {
                case .class, .struct: .class
                case .field: .variableDeclaration
                case .function, .method: .function
                }
            return GravityAnnotation(
                name: a.name,
                target: .init(kind: kind, identifier: name, parentIdentifier: parent),
                arguments: a.arguments.map { .init(label: $0.label, value: $0.value.gravityValue) },
                source: .init(fileID: a.fileID, line: a.line, column: a.column)
            )
        }
    }
}
extension NativeLiteral {
    var gravityValue: GravityAnnotation.Value {
        switch self {
        case .null: .null
        case .boolean(let v): .boolean(v)
        case .integer(let v): .integer(v)
        case .double(let v): .double(v)
        case .string(let v): .string(v)
        case .identifier(let v): .identifier(v)
        case .list(let v): .list(v.map(\.gravityValue))
        }
    }
    var reflected: ReflectedFieldValue? {
        switch self {
        case .null: .null
        case .boolean(let v): .bool(v)
        case .integer(let v): Int(exactly: v).map(ReflectedFieldValue.int)
        case .double(let v): .double(v)
        case .string(let v): .string(v)
        case .list(let v):
            if v.allSatisfy({ $0.reflected != nil }) { .array(v.compactMap(\.reflected)) } else { nil }
        case .identifier: nil
        }
    }
}
extension ReflectedFieldValue {
    var nativeValue: NativeValue {
        switch self {
        case .null: .null
        case .bool(let v): .boolean(v)
        case .int(let v): .integer(Int64(v))
        case .double(let v): .double(v)
        case .string(let v): .string(v)
        case .array(let v): .list(v.map(\.nativeValue))
        case .object(let v): .host(NativeReadOnlyFields(v))
        }
    }
}

func nativeExportedFields(_ type: NativeType) throws -> [String: ReflectedFieldValue] {
    var result: [String: ReflectedFieldValue] = [:]
    for field in type.fields where field.declaration.attribute("export") != nil || field.declaration.attribute("network_field") != nil {
        guard let value = field.defaultValue.reflected else {
            throw AdaScriptError.invalidManifest("Native exported field '\(type.name).\(field.declaration.name)' has an unsupported default")
        }
        result[field.declaration.name] = value
    }
    return result
}

struct NativeMetadata {
    let components: [RuntimeComponentDescriptor]
    let resources: [String: NativeResourceSchema]
    let plans: [AnnotatedSystemPlan]
    let scriptables: [NativeType]
    let dataSchemas: [AdaScriptDataSchema]
    let networkCommands: [AdaScriptNetworkCommandSchema]

    init(module: NativeModule, sources: [AdaScriptSource] = [], startupSystemIdentifier: String? = nil) throws {
        dataSchemas = try AdaScriptSchemaParser.parse(sources: sources)
        networkCommands = try AdaScriptSchemaParser.parseNetworkCommands(sources: sources)
        var components: [RuntimeComponentDescriptor] = []
        var resources: [String: NativeResourceSchema] = [:]
        var bindings: [AdaScriptResourceBinding] = []
        var scriptables: [NativeType] = []
        var identifiers = Set<String>()
        let unsupported = Set(["view", "tool"])
        for declaration in module.declarations {
            if let attribute = declaration.attributes.first(where: { unsupported.contains($0.name) }) {
                throw AdaScriptError.invalidManifest("Native AdaScript host integration for @\(attribute.name) is not available")
            }
        }
        if sources.isEmpty,
            module.declarations.contains(where: { $0.attributes.contains(where: { ["replicated_component", "network_command", "rpc", "remote_commands"].contains($0.name) }) }) {
            throw AdaScriptError.invalidManifest("Native networking requires source schema metadata")
        }
        for type in module.types {
            let data = type.declaration.attributes.filter { $0.name == "component" || $0.name == "resource" || $0.name == "replicated_component" }
            if !data.isEmpty {
                guard data.count == 1, type.isStruct else { throw AdaScriptError.invalidManifest("Native data declarations require one annotation on a struct") }
                let annotation = data[0]
                let id = try annotation.requireString("id")
                guard identifiers.insert(id).inserted else { throw AdaScriptError.invalidManifest("Duplicate native schema id '\(id)'") }
                let defaults = try nativeExportedFields(type)
                guard !defaults.isEmpty else { throw AdaScriptError.invalidManifest("Native data '\(type.name)' requires @export fields") }
                if annotation.name != "resource" {
                    let names = type.fields.map(\.declaration.name).filter { defaults[$0] != nil }
                    components.append(RuntimeComponentDescriptor(stableID: id, name: type.name, fieldNames: names, defaultValues: names.compactMap { defaults[$0] }))
                } else {
                    resources[type.name] = NativeResourceSchema(name: type.name, identifier: id, defaults: defaults, autoInsert: try annotation.boolean("autoInsert"))
                }
            }
            if type.declaration.attribute("scriptable") != nil {
                guard !type.isStruct else { throw AdaScriptError.invalidManifest("@scriptable requires a class") }
                scriptables.append(type)
            }
            if let system = type.declaration.attribute("system") {
                guard !type.isStruct, type.methods.contains(where: { $0.name == "update" && $0.parameters.count == 1 }) else {
                    throw AdaScriptError.invalidManifest("@system requires a class with update(context)")
                }
                _ = try system.requireString("id", default: type.name)
                _ = try system.requireString("scheduler", default: "update")
                for field in type.fields {
                    if let resource = field.declaration.attribute("resource") {
                        bindings.append(
                            AdaScriptResourceBinding(
                                isOptional: try resource.boolean("optional"),
                                propertyName: field.declaration.name,
                                resourceName: try resource.bindingType(),
                                systemName: type.name
                            )
                        )
                    }
                }
            }
        }
        self.components = components
        self.resources = resources
        self.scriptables = scriptables
        let remoteBindings = try AdaScriptSchemaParser.parseRemoteCommandBindings(sources: sources)
        let knownCommands = Set(networkCommands.map(\.name))
        if let unknown = remoteBindings.first(where: { !knownCommands.contains($0.commandName) }) {
            throw AdaScriptError.invalidManifest("Native @remote_commands references unknown command '\(unknown.commandName)'")
        }
        var plans = try AdaScriptSystemPlanBuilder.makePlans(
            from: module.declarations.flatMap(\.gravityAnnotations),
            remoteCommandBindings: remoteBindings,
            rpcMethodBindings: try AdaScriptSchemaParser.parseRPCMethodBindings(sources: sources),
            resourceBindings: bindings,
            systemCapabilities: try AdaScriptSchemaParser.parseSystemCapabilities(sources: sources)
        )
        if let startupSystemIdentifier {
            guard let index = plans.firstIndex(where: { $0.identifier == startupSystemIdentifier }), plans[index].scheduler == .startup else {
                throw AdaScriptError.invalidManifest("Native startup system must match an @system id with scheduler: startup")
            }
            let startup = plans.remove(at: index)
            plans.insert(startup, at: 0)
        }
        self.plans = plans
    }
}
#endif
