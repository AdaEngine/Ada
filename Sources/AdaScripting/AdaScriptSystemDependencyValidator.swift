@_spi(Scripting) import AdaECS
import AdaScriptCompilerCore
import Foundation
import Gravity

enum AdaScriptSystemPlanBuilder {
    /// `path:line:column: ` for an annotation whose file is known, else an empty prefix.
    static func locationPrefix(of annotation: GravityAnnotation, pathsByFileID: [UInt32: String]) -> String {
        guard let path = pathsByFileID[annotation.source.fileID] else {
            return ""
        }
        return "\(path):\(annotation.source.line):\(annotation.source.column): "
    }

    static func makePlans(
        from annotations: [GravityAnnotation],
        pathsByFileID: [UInt32: String] = [:],
        remoteCommandBindings: [AdaScriptRemoteCommandBinding],
        rpcMethodBindings: [AdaScriptRPCMethodBinding],
        resourceBindings: [AdaScriptResourceBinding],
        systemCapabilities: [AdaScriptSystemCapabilities]
    ) throws -> [AnnotatedSystemPlan] {
        let systemAnnotations = annotations.filter { $0.name == "system" }
        let systemClassNames = Set(systemAnnotations.map(\.target.identifier))
        try validateAnnotationTargets(annotations, systemClassNames: systemClassNames, pathsByFileID: pathsByFileID)
        let plans = try systemAnnotations.map { annotation in
            try makeSystemPlan(
                annotation,
                pathsByFileID: pathsByFileID,
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
        systemClassNames: Set<String>,
        pathsByFileID: [UInt32: String]
    ) throws {
        func fail(_ annotation: GravityAnnotation, _ message: String) -> AdaScriptError {
            .invalidManifest(locationPrefix(of: annotation, pathsByFileID: pathsByFileID) + message)
        }
        for query in annotations where query.name == "query" {
            guard let parent = query.target.parentIdentifier, systemClassNames.contains(parent) else {
                throw fail(query, "@query must be declared inside an @system class")
            }
        }
        for capability in annotations where capability.name == "exclusiveWorld" || capability.name == "access" {
            guard
                capability.target.kind == .class,
                systemClassNames.contains(capability.target.identifier)
            else {
                throw fail(capability, "@\(capability.name) can only annotate an @system class")
            }
        }
        for event in annotations where event.name == "events" || event.name == "eventWriter" {
            guard
                event.target.kind == .variableDeclaration,
                let parent = event.target.parentIdentifier,
                systemClassNames.contains(parent)
            else {
                throw fail(event, "@\(event.name) must annotate a stored property inside an @system class")
            }
        }
        for dependency in annotations where dependency.name == "after" || dependency.name == "before" {
            guard
                dependency.target.kind == .class,
                systemClassNames.contains(dependency.target.identifier)
            else {
                throw fail(dependency, "@\(dependency.name) can only annotate an @system class")
            }
        }
    }

    private static func makeSystemPlan(
        _ annotation: GravityAnnotation,
        pathsByFileID: [UInt32: String],
        annotations: [GravityAnnotation],
        remoteCommandBindings: [AdaScriptRemoteCommandBinding],
        rpcMethodBindings: [AdaScriptRPCMethodBinding],
        resourceBindings: [AdaScriptResourceBinding],
        systemCapabilities: [AdaScriptSystemCapabilities]
    ) throws -> AnnotatedSystemPlan {
        guard annotation.target.kind == .class else {
            throw AdaScriptError.invalidManifest(locationPrefix(of: annotation, pathsByFileID: pathsByFileID) + "@system can only annotate a class")
        }
        let className = annotation.target.identifier
        return try AnnotatedSystemPlan(
            source: AnnotatedSourceLocation(
                column: Int(annotation.source.column),
                line: Int(annotation.source.line),
                path: pathsByFileID[annotation.source.fileID]
            ),
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
                .map { query in
                    try makeQueryPlan(
                        query,
                        usage: systemCapabilities.first { $0.systemName == className }?.queryUsage
                            .first { $0.propertyName == query.target.identifier },
                        pathsByFileID: pathsByFileID
                    )
                },
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
                        access: $0.access,
                        isOptional: $0.isOptional,
                        propertyName: $0.propertyName,
                        resourceName: $0.resourceName
                    )
                },
            usesDeferredCommands:
                systemCapabilities
                .first { $0.systemName == className }?
                .usesDeferredCommands == true,
            isExclusiveWorld: annotations.contains { $0.name == "exclusiveWorld" && $0.target.identifier == className },
            access: try makeAccessPlan(annotations.filter { $0.name == "access" && $0.target.identifier == className }),
            eventReaders: try makeEventBindings(annotations, named: "events", className: className),
            eventWriters: try makeEventBindings(annotations, named: "eventWriter", className: className)
        )
    }

    private static func makeAccessPlan(_ annotations: [GravityAnnotation]) throws -> AnnotatedAccessPlan? {
        guard let annotation = annotations.first else {
            return nil
        }
        guard annotations.count == 1 else {
            throw AdaScriptError.invalidManifest("@access can only be declared once per system")
        }
        for argument in annotation.arguments where argument.label != "read" && argument.label != "write" {
            throw AdaScriptError.invalidManifest("@access only accepts read: and write: component lists")
        }
        let read = annotation.identifierListArgument(label: "read")
        let write = annotation.identifierListArgument(label: "write")
        guard !read.isEmpty || !write.isEmpty else {
            throw AdaScriptError.invalidManifest("@access requires at least one read: or write: component")
        }
        return AnnotatedAccessPlan(read: read, write: write)
    }

    private static func makeEventBindings(
        _ annotations: [GravityAnnotation],
        named name: String,
        className: String
    ) throws -> [AnnotatedEventPlan] {
        try annotations
            .filter { $0.name == name && $0.target.parentIdentifier == className }
            .map { annotation in
                guard
                    annotation.arguments.count == 1,
                    annotation.arguments[0].label == nil,
                    let eventName = annotation.arguments[0].value.identifierValue ?? annotation.arguments[0].value.stringValue
                else {
                    throw AdaScriptError.invalidManifest("@\(name) requires exactly one event name")
                }
                return AnnotatedEventPlan(eventName: eventName, propertyName: annotation.target.identifier)
            }
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

    private static let queryLabels: Set<String> = ["optional", "with", "without", "changed", "added"]

    private static func makeQueryPlan(
        _ annotation: GravityAnnotation,
        usage: AdaScriptQueryUsage?,
        pathsByFileID: [UInt32: String]
    ) throws -> AnnotatedQueryPlan {
        func fail(_ message: String) -> AdaScriptError {
            .invalidManifest(locationPrefix(of: annotation, pathsByFileID: pathsByFileID) + message)
        }
        guard annotation.target.kind == .variableDeclaration else {
            throw fail("@query can only annotate a stored property")
        }
        for argument in annotation.arguments {
            guard let label = argument.label else { continue }
            guard queryLabels.contains(label) else {
                let hint = label == "where" ? "; boolean predicates are not supported yet" : ""
                throw fail("@query does not support '\(label):'\(hint). Supported clauses: optional, with, without, changed, added")
            }
        }
        func references(_ values: [GravityAnnotation.Value]) throws -> [(name: String, alias: String?)] {
            try values.map { value in
                guard let text = value.identifierValue ?? value.stringValue else {
                    throw fail("@query component references must be names")
                }
                let pieces = text.components(separatedBy: " as ")
                return (pieces[0], pieces.count > 1 ? pieces[1] : nil)
            }
        }
        func labelled(_ label: String) throws -> [(name: String, alias: String?)] {
            var values: [GravityAnnotation.Value] = []
            for argument in annotation.arguments where argument.label == label {
                if case let .list(items) = argument.value { values += items } else { values.append(argument.value) }
            }
            return try references(values)
        }
        let required = try references(annotation.arguments.filter { $0.label == nil }.map(\.value))
        guard !required.isEmpty else {
            throw fail("@query requires at least one fetched component")
        }
        let optional = try labelled("optional")
        let fetched = required.map { AnnotatedQueryComponent(name: $0.name, alias: $0.alias, isOptional: false) }
            + optional.map { AnnotatedQueryComponent(name: $0.name, alias: $0.alias, isOptional: true) }
        return AnnotatedQueryPlan(
            propertyName: annotation.target.identifier,
            components: fetched,
            withComponents: try labelled("with").map(\.name),
            withoutComponents: try labelled("without").map(\.name),
            changedComponents: try labelled("changed").map(\.name),
            addedComponents: try labelled("added").map(\.name),
            usage: usage,
            source: AnnotatedSourceLocation(
                column: Int(annotation.source.column),
                line: Int(annotation.source.line),
                path: pathsByFileID[annotation.source.fileID]
            )
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
                if case .afterIfPresent = dependency, systemsByIdentifier[targetIdentifier]?.scheduler != system.scheduler {
                    continue
                }
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
                case .after, .afterIfPresent:
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
            let .after(identifier),
            let .afterIfPresent(identifier):
            identifier
        }
    }
}
