@_spi(Scripting) import AdaECS
import AdaScriptCompilerCore
import Gravity

enum AdaScriptSystemPlanBuilder {
    static func makePlans(
        from annotations: [GravityAnnotation],
        remoteCommandBindings: [AdaScriptRemoteCommandBinding],
        rpcMethodBindings: [AdaScriptRPCMethodBinding],
        resourceBindings: [AdaScriptResourceBinding],
        systemCapabilities: [AdaScriptSystemCapabilities]
    ) throws -> [AnnotatedSystemPlan] {
        let systemAnnotations = annotations.filter { $0.name == "system" }
        guard !systemAnnotations.isEmpty else {
            throw AdaScriptError.invalidManifest("Ada Script module must declare at least one @system class")
        }

        let systemClassNames = Set(systemAnnotations.map(\.target.identifier))
        try validateAnnotationTargets(annotations, systemClassNames: systemClassNames)
        let plans = try systemAnnotations.map {
            try makeSystemPlan(
                $0,
                annotations: annotations,
                remoteCommandBindings: remoteCommandBindings,
                rpcMethodBindings: rpcMethodBindings,
                resourceBindings: resourceBindings,
                systemCapabilities: systemCapabilities
            )
        }
        var identifiers = Set<String>()
        for plan in plans where !identifiers.insert(plan.identifier).inserted {
            throw AdaScriptError.invalidManifest("system identifiers must be unique")
        }
        try AdaScriptSystemDependencyValidator.validate(
            plans.map {
                AdaScriptSystemDependencyDescription(
                    dependencies: $0.dependencies,
                    identifier: $0.identifier,
                    scheduler: $0.scheduler
                )
            }
        )
        return plans
    }

    private static func validateAnnotationTargets(
        _ annotations: [GravityAnnotation],
        systemClassNames: Set<String>
    ) throws {
        for query in annotations where query.name == "query" {
            guard let parent = query.target.parentIdentifier, systemClassNames.contains(parent) else {
                throw AdaScriptError.invalidManifest("@query must be declared inside an @system class")
            }
        }
        for dependency in annotations where dependency.name == "after" || dependency.name == "before" {
            guard
                dependency.target.kind == .class,
                systemClassNames.contains(dependency.target.identifier)
            else {
                throw AdaScriptError.invalidManifest("@\(dependency.name) can only annotate an @system class")
            }
        }
    }

    private static func makeSystemPlan(
        _ annotation: GravityAnnotation,
        annotations: [GravityAnnotation],
        remoteCommandBindings: [AdaScriptRemoteCommandBinding],
        rpcMethodBindings: [AdaScriptRPCMethodBinding],
        resourceBindings: [AdaScriptResourceBinding],
        systemCapabilities: [AdaScriptSystemCapabilities]
    ) throws -> AnnotatedSystemPlan {
        guard annotation.target.kind == .class else {
            throw AdaScriptError.invalidManifest("@system can only annotate a class")
        }
        let className = annotation.target.identifier
        return try AnnotatedSystemPlan(
            className: className,
            dependencies:
                annotations
                .filter { ($0.name == "after" || $0.name == "before") && $0.target.identifier == className }
                .map(makeSystemDependency),
            identifier: annotation.stringArgument(label: "id") ?? className,
            scheduler: SchedulerName(rawValue: annotation.stringArgument(label: "scheduler") ?? "update"),
            queries:
                annotations
                .filter { $0.name == "query" && $0.target.parentIdentifier == className }
                .map(makeQueryPlan),
            remoteCommands:
                remoteCommandBindings
                .filter { $0.systemName == className }
                .map {
                    AnnotatedRemoteCommandPlan(
                        commandName: $0.commandName,
                        propertyName: $0.propertyName
                    )
                },
            rpcMethods: rpcMethodBindings
                .filter { $0.systemName == className }
                .map { AnnotatedRPCMethodPlan(commandName: $0.commandName, fieldNames: $0.fieldNames) },
            resources:
                resourceBindings
                .filter { $0.systemName == className }
                .map {
                    AnnotatedResourcePlan(
                        isOptional: $0.isOptional,
                        propertyName: $0.propertyName,
                        resourceName: $0.resourceName
                    )
                },
            usesDeferredCommands:
                systemCapabilities
                .first { $0.systemName == className }?
                .usesDeferredCommands == true
        )
    }

    private static func makeSystemDependency(_ annotation: GravityAnnotation) throws -> SystemDependency {
        guard
            annotation.arguments.count == 1,
            let identifier = annotation.stringArgument(label: "id")
        else {
            throw AdaScriptError.invalidManifest("@\(annotation.name) requires exactly one string id")
        }
        return annotation.name == "before" ? .before(identifier) : .after(identifier)
    }

    private static func makeQueryPlan(_ annotation: GravityAnnotation) throws -> AnnotatedQueryPlan {
        guard annotation.target.kind == .variableDeclaration else {
            throw AdaScriptError.invalidManifest("@query can only annotate a stored property")
        }
        let components = annotation.arguments.compactMap { argument -> String? in
            guard argument.label == nil else {
                return nil
            }
            return argument.value.identifierValue
        }
        guard !components.isEmpty else {
            throw AdaScriptError.invalidManifest("@query requires at least one fetched component")
        }
        return AnnotatedQueryPlan(
            propertyName: annotation.target.identifier,
            components: components,
            withComponents: annotation.identifierListArgument(label: "with"),
            withoutComponents: annotation.identifierListArgument(label: "without")
        )
    }
}

struct AdaScriptSystemDependencyDescription {
    let dependencies: [SystemDependency]
    let identifier: String
    let scheduler: SchedulerName
}

enum AdaScriptSystemDependencyValidator {
    static func validate(_ systems: [AdaScriptSystemDependencyDescription]) throws {
        let systemsByIdentifier = Dictionary(uniqueKeysWithValues: systems.map { ($0.identifier, $0) })
        var outgoing = Dictionary(uniqueKeysWithValues: systems.map { ($0.identifier, [String]()) })

        for system in systems {
            for dependency in system.dependencies {
                let targetIdentifier = dependency.identifier
                guard let target = systemsByIdentifier[targetIdentifier] else {
                    throw AdaScriptError.invalidManifest(
                        "system '\(system.identifier)' depends on unknown system '\(targetIdentifier)'"
                    )
                }
                guard targetIdentifier != system.identifier else {
                    throw AdaScriptError.invalidManifest("system '\(system.identifier)' cannot depend on itself")
                }
                guard target.scheduler == system.scheduler else {
                    throw AdaScriptError.invalidManifest(
                        "systems '\(system.identifier)' and '\(targetIdentifier)' must use the same scheduler"
                    )
                }
                switch dependency {
                case .before:
                    outgoing[system.identifier, default: []].append(targetIdentifier)
                case .after:
                    outgoing[targetIdentifier, default: []].append(system.identifier)
                }
            }
        }

        try validateAcyclic(systems: systems, outgoing: outgoing)
    }

    private static func validateAcyclic(
        systems: [AdaScriptSystemDependencyDescription],
        outgoing: [String: [String]]
    ) throws {
        var visited = Set<String>()
        var visiting = Set<String>()
        var path: [String] = []

        func visit(_ identifier: String) throws {
            if visiting.contains(identifier) {
                let cycleStart = path.firstIndex(of: identifier) ?? path.startIndex
                let cycle = Array(path[cycleStart...]) + [identifier]
                throw AdaScriptError.invalidManifest("system dependency cycle: \(cycle.joined(separator: " -> "))")
            }
            guard visited.insert(identifier).inserted else {
                return
            }
            visiting.insert(identifier)
            path.append(identifier)
            for target in outgoing[identifier, default: []] {
                try visit(target)
            }
            _ = path.popLast()
            visiting.remove(identifier)
        }

        for system in systems {
            try visit(system.identifier)
        }
    }
}

extension SystemDependency {
    var identifier: String {
        switch self {
        case let .before(identifier),
            let .after(identifier):
            identifier
        }
    }
}
