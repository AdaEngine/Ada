extension Parser {
    mutating func parseTool(
        name: String,
        annotation: Annotation,
        line: Int
    ) throws -> AdaScriptToolSchema {
        let supportedArguments: Set<String> = ["api", "id", "name", "permissions", "platforms", "version"]
        guard
            annotation.positionalArguments.isEmpty,
            annotation.arguments.keys.allSatisfy(supportedArguments.contains)
        else {
            throw toolError("@tool on \(name) contains unsupported arguments")
        }
        guard case let .string(id)? = annotation.arguments["id"], !id.isEmpty else {
            throw toolError("@tool on \(name) requires id: \"...\"")
        }
        let displayName = try toolStringArgument(
            "name",
            in: annotation,
            default: humanizedAdaScriptViewTitle(name),
            declarationName: name
        )
        let version = try toolStringArgument("version", in: annotation, default: "1.0.0", declarationName: name)
        guard Self.isToolSemanticVersion(version) else {
            throw toolError("@tool version on \(name) must use major.minor.patch")
        }
        let apiVersion = try toolAPIVersion(in: annotation, declarationName: name)
        let platformNames = try toolStringListArgument(
            "platforms",
            in: annotation,
            default: ["macos", "ipados"],
            declarationName: name
        )
        let permissionNames = try toolStringListArgument(
            "permissions",
            in: annotation,
            default: [],
            declarationName: name
        )
        guard Set(platformNames).count == platformNames.count else {
            throw toolError("@tool platforms on \(name) must be unique")
        }
        guard Set(permissionNames).count == permissionNames.count else {
            throw toolError("@tool permissions on \(name) must be unique")
        }
        return AdaScriptToolSchema(
            apiVersion: apiVersion,
            className: name,
            id: id,
            line: line,
            name: displayName,
            permissions: try toolPermissions(permissionNames, declarationName: name),
            platforms: try toolPlatforms(platformNames, declarationName: name),
            sourcePath: path,
            version: version
        )
    }

    private func toolAPIVersion(in annotation: Annotation, declarationName: String) throws -> Int {
        if case let .number(value)? = annotation.arguments["api"], let parsed = Int(value), parsed > 0 {
            return parsed
        }
        guard annotation.arguments["api"] != nil else {
            return 1
        }
        throw toolError("@tool api on \(declarationName) must be a positive integer")
    }

    private func toolStringArgument(
        _ key: String,
        in annotation: Annotation,
        default defaultValue: String,
        declarationName: String
    ) throws -> String {
        guard let value = annotation.arguments[key] else {
            return defaultValue
        }
        guard case let .string(string) = value, !string.isEmpty else {
            throw toolError("@tool \(key) on \(declarationName) must be a non-empty string")
        }
        return string
    }

    private func toolStringListArgument(
        _ key: String,
        in annotation: Annotation,
        default defaultValue: [String],
        declarationName: String
    ) throws -> [String] {
        guard let value = annotation.arguments[key] else {
            return defaultValue
        }
        guard case let .list(values) = value else {
            throw toolError("@tool \(key) on \(declarationName) must be a string list")
        }
        return try values.map { value in
            guard case let .string(string) = value, !string.isEmpty else {
                throw toolError("@tool \(key) on \(declarationName) must contain non-empty strings")
            }
            return string
        }
    }

    private func toolPlatforms(_ values: [String], declarationName: String) throws -> [AdaScriptToolPlatform] {
        try values.map { value in
            guard let platform = AdaScriptToolPlatform(rawValue: value) else {
                throw toolError("@tool on \(declarationName) uses unsupported platform '\(value)'")
            }
            return platform
        }
    }

    private func toolPermissions(_ values: [String], declarationName: String) throws -> [AdaScriptToolPermission] {
        try values.map { value in
            guard let permission = AdaScriptToolPermission(rawValue: value) else {
                throw toolError("@tool on \(declarationName) uses unsupported permission '\(value)'")
            }
            return permission
        }
    }

    private func toolError(_ message: String) -> AdaScriptSchemaError {
        .invalid(path: path, message: message)
    }

    private static func isToolSemanticVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3
            && components.allSatisfy { component in
                !component.isEmpty && component.allSatisfy(\.isNumber)
            }
    }
}
