/// Builds a declaration tree and performs best-effort type analysis without
/// changing AdaScript's dynamic runtime semantics. Consumers decide whether
/// reported type issues are ignored, displayed, or enforced.
public enum AdaScriptAnalyzer {
    public static func analyze(
        source: String,
        path: String = "<memory>",
        environment: AdaScriptTypeEnvironment = .standard
    ) -> AdaScriptSourceAnalysis {
        analyze(
            sources: [AdaScriptCompilerSource(path: path, source: source)],
            environment: environment
        ).sources[0]
    }

    public static func analyze(
        sources: [AdaScriptCompilerSource],
        environment: AdaScriptTypeEnvironment = .standard
    ) -> AdaScriptModuleAnalysis {
        let documents = sources.map { source in
            AdaScriptSyntaxParser(source: source.source, path: source.path).parse()
        }
        var analyzer = ModuleAnalyzer(documents: documents, environment: environment)
        return analyzer.analyze()
    }
}

private struct ModuleAnalyzer {
    private struct Binding {
        var isConstrained: Bool
        var type: AdaScriptType
    }

    private let documents: [AdaScriptParsedDocument]
    private var environment: AdaScriptTypeEnvironment
    private var functions: [String: AdaScriptCallableType] = [:]
    private var globalBindings: [String: Binding] = [:]

    init(documents: [AdaScriptParsedDocument], environment: AdaScriptTypeEnvironment) {
        self.documents = documents
        self.environment = environment
    }

    mutating func analyze() -> AdaScriptModuleAnalysis {
        collectDeclarations()
        return AdaScriptModuleAnalysis(sources: documents.map(analyzeDocument))
    }

    private mutating func collectDeclarations() {
        for document in documents {
            for function in document.functions {
                functions[function.syntax.name] = callable(for: function.syntax)
            }
            for type in document.types {
                var members = environment.members[type.syntax.name] ?? [:]
                for binding in type.bindings {
                    members[binding.syntax.name] = AdaScriptMemberType(
                        type: binding.syntax.declaredType ?? inferredLiteralType(
                            in: binding.initializerRange,
                            tokens: document.tokens
                        )
                    )
                }
                for function in type.functions {
                    let signature = callable(for: function.syntax)
                    members[function.syntax.name] = AdaScriptMemberType(type: signature.returnType, callable: signature)
                }
                if type.syntax.annotations.contains(where: { $0.name == "resource" }) {
                    members["available"] = AdaScriptMemberType(
                        type: .bool,
                        callable: AdaScriptCallableType(parameters: [], returnType: .bool),
                        detail: "available() -> Bool — whether an optional resource is bound",
                        insertText: "available()",
                        kind: .method
                    )
                }
                environment.members[type.syntax.name] = members
            }
        }

        for document in documents {
            for binding in document.bindings {
                let inferred = inferExpression(
                    binding.initializerRange,
                    tokens: document.tokens,
                    scope: globalBindings
                )
                globalBindings[binding.syntax.name] = Binding(
                    isConstrained: binding.syntax.declaredType != nil,
                    type: binding.syntax.declaredType ?? inferred
                )
            }
        }
        for (name, type) in environment.values where globalBindings[name] == nil {
            globalBindings[name] = Binding(isConstrained: true, type: type)
        }
    }
}

private extension ModuleAnalyzer {
    private func analyzeDocument(_ document: AdaScriptParsedDocument) -> AdaScriptSourceAnalysis {
        var inferredTypes: [String: AdaScriptType] = [:]
        var issues: [AdaScriptTypeIssue] = []

        for binding in document.bindings {
            let actual = inferExpression(binding.initializerRange, tokens: document.tokens, scope: globalBindings)
            inferredTypes[binding.syntax.name] = binding.syntax.declaredType ?? actual
            appendAssignmentIssue(
                expected: binding.syntax.declaredType,
                actual: actual,
                path: document.syntax.path,
                range: expressionRange(binding.initializerRange, tokens: document.tokens) ?? binding.syntax.range,
                into: &issues
            )
        }

        for type in document.types {
            var memberScope = globalBindings
            for binding in type.bindings {
                let actual = inferExpression(binding.initializerRange, tokens: document.tokens, scope: memberScope)
                let type = binding.syntax.declaredType ?? queryType(for: binding.syntax) ?? actual
                memberScope[binding.syntax.name] = Binding(
                    isConstrained: binding.syntax.declaredType != nil,
                    type: type
                )
                inferredTypes[binding.syntax.name] = type
                appendAssignmentIssue(
                    expected: binding.syntax.declaredType,
                    actual: actual,
                    path: document.syntax.path,
                    range: expressionRange(binding.initializerRange, tokens: document.tokens) ?? binding.syntax.range,
                    into: &issues
                )
            }
            for function in type.functions {
                analyzeFunction(
                    function,
                    owner: type,
                    document: document,
                    baseScope: memberScope,
                    inferredTypes: &inferredTypes,
                    issues: &issues
                )
            }
        }

        for function in document.functions {
            analyzeFunction(
                function,
                owner: nil,
                document: document,
                baseScope: globalBindings,
                inferredTypes: &inferredTypes,
                issues: &issues
            )
        }
        return AdaScriptSourceAnalysis(inferredTypes: inferredTypes, syntax: document.syntax, typeIssues: issues)
    }

    private func analyzeFunction(
        _ function: AdaScriptParsedFunction,
        owner: AdaScriptParsedType?,
        document: AdaScriptParsedDocument,
        baseScope: [String: Binding],
        inferredTypes: inout [String: AdaScriptType],
        issues: inout [AdaScriptTypeIssue]
    ) {
        guard let bodyRange = function.bodyRange else {
            return
        }
        var scope = baseScope
        if let owner {
            scope["self"] = Binding(isConstrained: true, type: .named(owner.syntax.name))
        }
        for (offset, parameter) in function.syntax.parameters.enumerated() {
            let implicit = implicitParameterType(function: function.syntax, owner: owner, offset: offset)
            let type = parameter.declaredType ?? implicit ?? .unknown
            scope[parameter.name] = Binding(isConstrained: parameter.declaredType != nil, type: type)
            inferredTypes[parameter.name] = type
        }

        var index = bodyRange.lowerBound
        while index < bodyRange.upperBound {
            let token = document.tokens[index]
            if token.text == "var" || token.text == "const" {
                index = analyzeLocalBinding(
                    at: index,
                    upperBound: bodyRange.upperBound,
                    document: document,
                    scope: &scope,
                    inferredTypes: &inferredTypes,
                    issues: &issues
                )
                continue
            }
            if token.text == "for" {
                inferLoopBinding(at: index, upperBound: bodyRange.upperBound, tokens: document.tokens, scope: &scope, inferredTypes: &inferredTypes)
            }
            if token.text == "return" {
                let valueRange = statementExpressionRange(after: index, upperBound: bodyRange.upperBound, tokens: document.tokens)
                let actual = valueRange.isEmpty ? AdaScriptType.void : inferExpression(valueRange, tokens: document.tokens, scope: scope)
                if let expected = function.syntax.returnType, !expected.accepts(actual) {
                    issues.append(
                        AdaScriptTypeIssue(
                            kind: .returnType,
                            message: "Cannot return \(actual.displayName) from function returning \(expected.displayName)",
                            path: document.syntax.path,
                            range: expressionRange(valueRange, tokens: document.tokens) ?? token.range
                        )
                    )
                }
            }
            if token.text == "=", !isEqualityOperator(at: index, tokens: document.tokens) {
                analyzeAssignment(at: index, upperBound: bodyRange.upperBound, document: document, scope: scope, issues: &issues)
            }
            if token.text == "." {
                analyzeMemberAccess(at: index, upperBound: bodyRange.upperBound, document: document, scope: scope, issues: &issues)
            }
            if token.kind == .identifier, index + 1 < bodyRange.upperBound, document.tokens[index + 1].text == "(" {
                analyzeCall(at: index, upperBound: bodyRange.upperBound, document: document, scope: scope, issues: &issues)
            }
            index += 1
        }
    }

    private func analyzeLocalBinding(
        at index: Int,
        upperBound: Int,
        document: AdaScriptParsedDocument,
        scope: inout [String: Binding],
        inferredTypes: inout [String: AdaScriptType],
        issues: inout [AdaScriptTypeIssue]
    ) -> Int {
        guard index + 1 < upperBound, document.tokens[index + 1].kind == .identifier else {
            return index + 1
        }
        let name = document.tokens[index + 1].text
        var cursor = index + 2
        var declaredType: AdaScriptType?
        if cursor < upperBound, document.tokens[cursor].text == ":" {
            cursor += 1
            if cursor < upperBound, document.tokens[cursor].kind == .identifier {
                declaredType = AdaScriptType(spelling: document.tokens[cursor].text)
                cursor += 1
            }
        }
        var initializerRange: Range<Int>?
        if cursor < upperBound, document.tokens[cursor].text == "=" {
            initializerRange = statementExpressionRange(after: cursor, upperBound: upperBound, tokens: document.tokens)
        }
        let actual = inferExpression(initializerRange, tokens: document.tokens, scope: scope)
        let type = declaredType ?? actual
        scope[name] = Binding(isConstrained: declaredType != nil, type: type)
        inferredTypes[name] = type
        appendAssignmentIssue(
            expected: declaredType,
            actual: actual,
            path: document.syntax.path,
            range: expressionRange(initializerRange, tokens: document.tokens) ?? document.tokens[index + 1].range,
            into: &issues
        )
        return initializerRange?.upperBound ?? cursor
    }

    private func analyzeAssignment(
        at index: Int,
        upperBound: Int,
        document: AdaScriptParsedDocument,
        scope: [String: Binding],
        issues: inout [AdaScriptTypeIssue]
    ) {
        guard index > 0 else {
            return
        }
        let receiverEnd = Self.compoundAssignmentOperators.contains(document.tokens[index - 1].text) ? index - 1 : index
        let leftRange = assignmentReceiverRange(endingBefore: receiverEnd, lowerBound: 0, tokens: document.tokens)
        let expected = resolveExpressionType(leftRange, tokens: document.tokens, scope: scope)
        let isConstrained: Bool
        if leftRange.count == 1, let name = leftRange.first.map({ document.tokens[$0].text }) {
            isConstrained = scope[name]?.isConstrained == true
        } else {
            isConstrained = expected != .unknown && expected != .any
        }
        guard isConstrained else {
            return
        }
        let valueRange = statementExpressionRange(after: index, upperBound: upperBound, tokens: document.tokens)
        let actual = inferExpression(valueRange, tokens: document.tokens, scope: scope)
        appendAssignmentIssue(
            expected: expected,
            actual: actual,
            path: document.syntax.path,
            range: expressionRange(valueRange, tokens: document.tokens) ?? document.tokens[index].range,
            into: &issues
        )
    }

    private func analyzeCall(
        at index: Int,
        upperBound: Int,
        document: AdaScriptParsedDocument,
        scope: [String: Binding],
        issues: inout [AdaScriptTypeIssue]
    ) {
        guard
            !Self.controlFlowNames.contains(document.tokens[index].text),
            let close = matchingIndex(
                openingAt: index + 1,
                opening: "(",
                closing: ")",
                upperBound: upperBound,
                tokens: document.tokens
            ),
            let callable = callable(at: index, tokens: document.tokens, scope: scope)
        else {
            return
        }
        let arguments = splitTopLevel((index + 2)..<close, separator: ",", tokens: document.tokens)
        for (offset, argument) in arguments.enumerated() where offset < callable.parameters.count {
            let expected = callable.parameters[offset]
            let actual = inferExpression(argument, tokens: document.tokens, scope: scope)
            guard !expected.accepts(actual) else {
                continue
            }
            issues.append(
                AdaScriptTypeIssue(
                    kind: .argumentType,
                    message: "Argument \(offset + 1) expects \(expected.displayName), got \(actual.displayName)",
                    path: document.syntax.path,
                    range: expressionRange(argument, tokens: document.tokens) ?? document.tokens[index].range
                )
            )
        }
    }

    private func analyzeMemberAccess(
        at index: Int,
        upperBound: Int,
        document: AdaScriptParsedDocument,
        scope: [String: Binding],
        issues: inout [AdaScriptTypeIssue]
    ) {
        guard index > 0, index + 1 < upperBound, document.tokens[index + 1].kind == .identifier else {
            return
        }
        let receiverRange = assignmentReceiverRange(endingBefore: index, lowerBound: 0, tokens: document.tokens)
        let receiverType = resolveExpressionType(receiverRange, tokens: document.tokens, scope: scope)
        guard hasKnownMembers(receiverType) else {
            return
        }
        let memberToken = document.tokens[index + 1]
        guard member(named: memberToken.text, on: receiverType) == nil else {
            return
        }
        issues.append(
            AdaScriptTypeIssue(
                kind: .memberAccess,
                message: "\(receiverType.displayName) has no member '\(memberToken.text)'",
                path: document.syntax.path,
                range: memberToken.range
            )
        )
    }
}

private extension ModuleAnalyzer {
    private func inferLoopBinding(
        at index: Int,
        upperBound: Int,
        tokens: [AdaScriptAnalysisToken],
        scope: inout [String: Binding],
        inferredTypes: inout [String: AdaScriptType]
    ) {
        guard index + 4 < upperBound, tokens[index + 1].text == "(" else {
            return
        }
        let variableIndex = tokens[index + 2].text == "var" ? index + 3 : index + 2
        let inIndex = variableIndex + 1
        let collectionIndex = inIndex + 1
        guard
            collectionIndex < upperBound,
            tokens[variableIndex].kind == .identifier,
            tokens[inIndex].text == "in"
        else {
            return
        }
        let collectionType = resolveExpressionType(collectionIndex..<(collectionIndex + 1), tokens: tokens, scope: scope)
        let elementType: AdaScriptType =
            switch collectionType {
            case let .list(element): element
            case let .query(components): .queryRow(components)
            default: .unknown
            }
        scope[tokens[variableIndex].text] = Binding(isConstrained: false, type: elementType)
        inferredTypes[tokens[variableIndex].text] = elementType
    }

    private func queryType(for binding: AdaScriptBindingSyntax) -> AdaScriptType? {
        guard let query = binding.annotations.first(where: { $0.name == "query" }) else {
            return nil
        }
        return .query(query.arguments.filter { $0.first?.isUppercase == true })
    }

    private func implicitParameterType(
        function: AdaScriptFunctionSyntax,
        owner: AdaScriptParsedType?,
        offset: Int
    ) -> AdaScriptType? {
        guard let owner else {
            return nil
        }
        let annotations = Set(owner.syntax.annotations.map(\.name))
        if annotations.contains("system"), function.name == "update", offset == 0 {
            return .named("$AdaSystemContext")
        }
        if annotations.contains("tool"), function.name == "activate", offset == 0 {
            return .named("$AdaEditorToolContext")
        }
        if annotations.contains("scriptable"), ["destroy", "fixedUpdate", "ready", "update"].contains(function.name), offset == 0 {
            return .named("$AdaScriptableContext")
        }
        if annotations.contains("scriptable"), function.name == "event" {
            return offset == 0 ? .list(.any) : (offset == 1 ? .named("$AdaScriptableContext") : nil)
        }
        return nil
    }

    private func callable(for function: AdaScriptFunctionSyntax) -> AdaScriptCallableType {
        AdaScriptCallableType(
            parameters: function.parameters.map { $0.declaredType ?? .unknown },
            returnType: function.returnType ?? .unknown
        )
    }

    private func callable(
        at index: Int,
        tokens: [AdaScriptAnalysisToken],
        scope: [String: Binding]
    ) -> AdaScriptCallableType? {
        let name = tokens[index].text
        if index >= 2, tokens[index - 1].text == "." {
            let receiverRange = assignmentReceiverRange(endingBefore: index - 1, lowerBound: 0, tokens: tokens)
            let receiverType = resolveExpressionType(receiverRange, tokens: tokens, scope: scope)
            return member(named: name, on: receiverType)?.callable
        }
        return functions[name] ?? environment.functions[name]
    }

    private func inferExpression(
        _ range: Range<Int>?,
        tokens: [AdaScriptAnalysisToken],
        scope: [String: Binding]
    ) -> AdaScriptType {
        guard var range, !range.isEmpty else {
            return .unknown
        }
        if range.count >= 3, tokens[range.lowerBound].kind == .identifier,
            tokens[range.lowerBound + 1].text == ":" {
            range = (range.lowerBound + 2)..<range.upperBound
        }
        while range.lowerBound < range.upperBound, ["await", "+", "-", "!"].contains(tokens[range.lowerBound].text) {
            range = (range.lowerBound + 1)..<range.upperBound
        }
        guard !range.isEmpty else {
            return .unknown
        }
        if containsTopLevelComparison(in: range, tokens: tokens) {
            return .bool
        }
        if containsTopLevelOperator("+", in: range, tokens: tokens) {
            let parts = splitTopLevel(range, separator: "+", tokens: tokens)
            let types = parts.map { inferExpression($0, tokens: tokens, scope: scope) }
            if types.contains(.string) {
                return .string
            }
            if types.contains(.float) {
                return .float
            }
            if types.allSatisfy({ $0 == .int }) {
                return .int
            }
        }
        if containsAnyTopLevelOperator(["-", "*", "/", "%"], in: range, tokens: tokens) {
            return range.contains(where: { tokens[$0].kind == .number && tokens[$0].text.contains(".") }) ? .float : .int
        }
        return resolveExpressionType(range, tokens: tokens, scope: scope)
    }

    private func resolveExpressionType(
        _ range: Range<Int>,
        tokens: [AdaScriptAnalysisToken],
        scope: [String: Binding]
    ) -> AdaScriptType {
        guard !range.isEmpty else {
            return .unknown
        }
        let first = tokens[range.lowerBound]
        switch first.kind {
        case .string:
            return .string
        case .number:
            return first.text.contains(".") ? .float : .int
        case .identifier:
            break
        default:
            if first.text == "[" {
                return collectionLiteralType(range, tokens: tokens, scope: scope)
            }
            if first.text == "(", range.upperBound - range.lowerBound >= 2 {
                return inferExpression((range.lowerBound + 1)..<(range.upperBound - 1), tokens: tokens, scope: scope)
            }
            return .unknown
        }

        if first.text == "true" || first.text == "false" {
            return .bool
        }
        if first.text == "null" {
            return .null
        }
        var type: AdaScriptType
        if range.lowerBound + 1 < range.upperBound, tokens[range.lowerBound + 1].text == "(" {
            if first.text.first?.isUppercase == true {
                type = .named(first.text)
            } else {
                type = functions[first.text]?.returnType ?? environment.functions[first.text]?.returnType ?? .unknown
            }
        } else {
            type = scope[first.text]?.type ?? environment.values[first.text] ?? (first.text.first?.isUppercase == true ? .named(first.text) : .unknown)
        }

        var cursor = range.lowerBound + 1
        while cursor + 1 < range.upperBound {
            guard tokens[cursor].text == ".", tokens[cursor + 1].kind == .identifier else {
                cursor += 1
                continue
            }
            let memberName = tokens[cursor + 1].text
            guard let resolved = member(named: memberName, on: type) else {
                return .unknown
            }
            type = resolved.callable?.returnType ?? resolved.type
            cursor += 2
            if cursor < range.upperBound, tokens[cursor].text == "(",
                let close = matchingIndex(openingAt: cursor, opening: "(", closing: ")", upperBound: range.upperBound, tokens: tokens) {
                cursor = close + 1
            }
        }
        return type
    }

    private func collectionLiteralType(
        _ range: Range<Int>,
        tokens: [AdaScriptAnalysisToken],
        scope: [String: Binding]
    ) -> AdaScriptType {
        guard range.count >= 2, tokens[range.lowerBound].text == "[" else {
            return .unknown
        }
        let contents = (range.lowerBound + 1)..<(range.upperBound - 1)
        if let colon = firstTopLevelToken(":", in: contents, tokens: tokens) {
            let keyRange = contents.lowerBound..<colon
            let valueRange = (colon + 1)..<contents.upperBound
            return .map(
                key: inferExpression(keyRange, tokens: tokens, scope: scope),
                value: inferExpression(valueRange, tokens: tokens, scope: scope)
            )
        }
        let elements = splitTopLevel(contents, separator: ",", tokens: tokens)
        let types = elements.map { inferExpression($0, tokens: tokens, scope: scope) }
        return .list(commonType(types))
    }

    private func member(named name: String, on type: AdaScriptType) -> AdaScriptMemberType? {
        switch type {
        case let .named(typeName):
            return environment.members[typeName]?[name]
        case let .queryRow(components):
            guard let component = components.first(where: { lowerCamelCase($0) == name }) else {
                return name == "id" ? AdaScriptMemberType(type: .int) : nil
            }
            return AdaScriptMemberType(type: .named(component))
        case let .list(element):
            if name == "count" {
                return AdaScriptMemberType(type: .int)
            }
            if name == "first" {
                return AdaScriptMemberType(type: element)
            }
            return nil
        default:
            return nil
        }
    }

    private func hasKnownMembers(_ type: AdaScriptType) -> Bool {
        return switch type {
        case let .named(typeName):
            environment.members[typeName] != nil
        case .list,
            .queryRow:
            true
        default:
            false
        }
    }
}

private extension ModuleAnalyzer {
    private func appendAssignmentIssue(
        expected: AdaScriptType?,
        actual: AdaScriptType,
        path: String,
        range: AdaScriptSourceRange,
        into issues: inout [AdaScriptTypeIssue]
    ) {
        guard let expected, !expected.accepts(actual) else {
            return
        }
        issues.append(
            AdaScriptTypeIssue(
                kind: .assignmentType,
                message: "Cannot assign \(actual.displayName) to \(expected.displayName)",
                path: path,
                range: range
            )
        )
    }

    private func inferredLiteralType(
        in range: Range<Int>?,
        tokens: [AdaScriptAnalysisToken]
    ) -> AdaScriptType {
        guard let range, let firstIndex = range.first else {
            return .unknown
        }
        let token = tokens[firstIndex]
        if token.kind == .string {
            return .string
        }
        if token.kind == .number {
            return token.text.contains(".") ? .float : .int
        }
        if token.text == "true" || token.text == "false" {
            return .bool
        }
        if token.text == "null" {
            return .null
        }
        return token.text.first?.isUppercase == true ? .named(token.text) : .unknown
    }

    private func commonType(_ types: [AdaScriptType]) -> AdaScriptType {
        guard let first = types.first else {
            return .unknown
        }
        if types.allSatisfy({ $0 == first }) {
            return first
        }
        if types.allSatisfy({ $0 == .int || $0 == .float }) {
            return .float
        }
        return .unknown
    }

    private func statementExpressionRange(
        after index: Int,
        upperBound: Int,
        tokens: [AdaScriptAnalysisToken]
    ) -> Range<Int> {
        let start = index + 1
        guard start < upperBound else {
            return start..<start
        }
        var depths = AnalysisDelimiterDepth()
        var cursor = start
        let startingLine = tokens[start].range.start.line
        while cursor < upperBound {
            let token = tokens[cursor]
            if depths.isTopLevel, token.text == ";" || token.text == "}" {
                break
            }
            if depths.isTopLevel, cursor > start, token.range.start.line > startingLine,
                Self.statementStarters.contains(token.text) {
                break
            }
            depths.consume(token.text)
            cursor += 1
        }
        return start..<cursor
    }

    private func assignmentReceiverRange(
        endingBefore index: Int,
        lowerBound: Int,
        tokens: [AdaScriptAnalysisToken]
    ) -> Range<Int> {
        var start = index - 1
        while start > lowerBound {
            let previous = tokens[start - 1].text
            if previous == "." || tokens[start].text == "." || tokens[start - 1].kind == .identifier {
                start -= 1
            } else {
                break
            }
        }
        return start..<index
    }

    private func expressionRange(
        _ range: Range<Int>?,
        tokens: [AdaScriptAnalysisToken]
    ) -> AdaScriptSourceRange? {
        guard let range, let first = range.first, let last = range.last else {
            return nil
        }
        return AdaScriptSourceRange(start: tokens[first].range.start, end: tokens[last].range.end)
    }

    private func splitTopLevel(
        _ range: Range<Int>,
        separator: String,
        tokens: [AdaScriptAnalysisToken]
    ) -> [Range<Int>] {
        guard !range.isEmpty else {
            return []
        }
        var result: [Range<Int>] = []
        var start = range.lowerBound
        var depths = AnalysisDelimiterDepth()
        for index in range {
            if depths.isTopLevel, tokens[index].text == separator {
                if start < index {
                    result.append(start..<index)
                }
                start = index + 1
            } else {
                depths.consume(tokens[index].text)
            }
        }
        if start < range.upperBound {
            result.append(start..<range.upperBound)
        }
        return result
    }

    private func firstTopLevelToken(
        _ text: String,
        in range: Range<Int>,
        tokens: [AdaScriptAnalysisToken]
    ) -> Int? {
        var depths = AnalysisDelimiterDepth()
        for index in range {
            if depths.isTopLevel, tokens[index].text == text {
                return index
            }
            depths.consume(tokens[index].text)
        }
        return nil
    }

    private func containsTopLevelComparison(
        in range: Range<Int>,
        tokens: [AdaScriptAnalysisToken]
    ) -> Bool {
        containsAnyTopLevelOperator(["<", ">", "==", "!=", "&&", "||"], in: range, tokens: tokens)
    }

    private func containsTopLevelOperator(
        _ value: String,
        in range: Range<Int>,
        tokens: [AdaScriptAnalysisToken]
    ) -> Bool {
        containsAnyTopLevelOperator([value], in: range, tokens: tokens)
    }

    private func containsAnyTopLevelOperator(
        _ values: Set<String>,
        in range: Range<Int>,
        tokens: [AdaScriptAnalysisToken]
    ) -> Bool {
        var depths = AnalysisDelimiterDepth()
        var index = range.lowerBound
        while index < range.upperBound {
            if depths.isTopLevel {
                let pair = index + 1 < range.upperBound ? tokens[index].text + tokens[index + 1].text : tokens[index].text
                if values.contains(pair) || values.contains(tokens[index].text) {
                    return true
                }
            }
            depths.consume(tokens[index].text)
            index += 1
        }
        return false
    }

    private func matchingIndex(
        openingAt index: Int,
        opening: String,
        closing: String,
        upperBound: Int,
        tokens: [AdaScriptAnalysisToken]
    ) -> Int? {
        var depth = 0
        for cursor in index..<upperBound {
            if tokens[cursor].text == opening {
                depth += 1
            } else if tokens[cursor].text == closing {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
        }
        return nil
    }

    private func isEqualityOperator(at index: Int, tokens: [AdaScriptAnalysisToken]) -> Bool {
        (index > 0 && ["!", "<", ">", "="].contains(tokens[index - 1].text))
            || (index + 1 < tokens.count && tokens[index + 1].text == "=")
    }

    private func lowerCamelCase(_ value: String) -> String {
        guard let first = value.first else {
            return value
        }
        return first.lowercased() + value.dropFirst()
    }

    private static let controlFlowNames: Set<String> = ["for", "if", "repeat", "switch", "while"]
    private static let compoundAssignmentOperators: Set<String> = ["%", "*", "+", "-", "/"]
    private static let statementStarters: Set<String> = [
        "break", "const", "continue", "for", "if", "repeat", "return", "switch", "var", "while",
    ]
}

private struct AnalysisDelimiterDepth {
    private var braces = 0
    private var brackets = 0
    private var parentheses = 0

    var isTopLevel: Bool {
        braces == 0 && brackets == 0 && parentheses == 0
    }

    mutating func consume(_ token: String) {
        switch token {
        case "(": parentheses += 1
        case ")": parentheses = max(0, parentheses - 1)
        case "[": brackets += 1
        case "]": brackets = max(0, brackets - 1)
        case "{": braces += 1
        case "}": braces = max(0, braces - 1)
        default: break
        }
    }
}
