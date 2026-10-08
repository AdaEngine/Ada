import AdaScriptCompilerCore

enum AdaScriptViewSourceGenerator {
    static func accessors(_ views: [AdaScriptViewSchema], moduleName: String) -> String {
        guard !views.isEmpty else {
            return ""
        }
        let declarations = views
            .map { view in
                """
                    @MainActor
                    static var \(accessorName(view.className)): AdaScriptView {
                        AdaScriptView(\(swiftStringLiteral(identifier(view, moduleName: moduleName))))
                    }
                """
            }
            .joined(separator: "\n\n")
        return """
        enum AdaScriptViewsGenerated {
        \(declarations)
        }
        """
    }

    static func registration(_ views: [AdaScriptViewSchema], moduleName: String) -> String {
        guard !views.isEmpty else {
            return ""
        }
        let declarations = views
            .map { view in
                let environment = view.environment
                    .map { binding in
                        "AdaScriptViewEnvironment(key: \(swiftStringLiteral(binding.key)), propertyName: \(swiftStringLiteral(binding.propertyName)))"
                    }
                    .joined(separator: ", ")
                return """
                            AdaScriptViewMetadata(
                                className: \(swiftStringLiteral(view.className)),
                                environment: [\(environment)],
                                identifier: \(swiftStringLiteral(identifier(view, moduleName: moduleName))),
                                isPreviewable: \(view.isPreviewable),
                                line: \(view.line),
                                sourcePath: \(swiftStringLiteral(view.sourcePath)),
                                title: \(swiftStringLiteral(view.title))
                            )
                """
            }
            .joined(separator: ",\n")
        return """
                try AdaScriptViewRegistry.register(
                    views: [
        \(declarations)
                    ],
                    sources: Self.sources,
                    moduleName: Self.moduleName
                )
        """
    }

    private static func accessorName(_ className: String) -> String {
        guard let first = className.first else {
            return "view"
        }
        return first.lowercased() + className.dropFirst()
    }

    private static func identifier(_ view: AdaScriptViewSchema, moduleName: String) -> String {
        view.isIDExplicit ? view.id : "\(moduleName).\(view.className)"
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
