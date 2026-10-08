import Foundation

enum EditorBuildStepState: Equatable, Sendable {
    case completed
    case failed
    case running
}

struct EditorBuildStep: Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var detail: String?
    var state: EditorBuildStepState
    var fractionCompleted: Float?
}

struct EditorBuildActivity: Equatable, Sendable {
    var title: String
    private(set) var steps: [EditorBuildStep]

    init(title: String) {
        self.title = title
        self.steps = [
            EditorBuildStep(
                id: "preparing",
                title: "Preparing",
                detail: nil,
                state: .running,
                fractionCompleted: nil
            )
        ]
    }

    var currentStep: EditorBuildStep? {
        steps.last(where: { $0.state == .running }) ?? steps.last
    }

    mutating func consume(_ output: String) {
        for line in output.components(separatedBy: .newlines) {
            guard let update = Self.stepUpdate(for: line) else {
                continue
            }
            setCurrentStep(
                id: update.id,
                title: update.title,
                detail: update.detail,
                fractionCompleted: update.fractionCompleted
            )
        }
    }

    mutating func consume(_ progress: SwiftPMWorkspaceProgress) {
        let update: StepUpdate? =
            switch progress.phase {
            case .loadingProjectMetadata:
                StepUpdate(id: "metadata", title: "Loading project metadata", detail: progress.detail)
            case .locatingToolchain:
                StepUpdate(id: "toolchain", title: "Locating Swift toolchain", detail: progress.detail)
            case .resolvingDependencies:
                StepUpdate(id: "dependencies", title: "Resolving dependencies", detail: progress.detail)
            case .describingPackage:
                StepUpdate(id: "package-graph", title: "Reading package graph", detail: progress.detail)
            case .startingSourceKitLSP:
                StepUpdate(id: "sourcekit-lsp", title: "Starting SourceKit-LSP", detail: progress.detail)
            case .scanningSources:
                StepUpdate(
                    id: "scanning",
                    title: "Scanning source files",
                    detail: progress.currentFile ?? progress.detail,
                    fractionCompleted: Self.fraction(completed: progress.completedFileCount, total: progress.totalFileCount)
                )
            case .indexingBuild:
                StepUpdate(
                    id: "indexing",
                    title: "Indexing Swift package",
                    detail: progress.currentTarget ?? progress.currentFile ?? progress.detail,
                    fractionCompleted: Self.fraction(completed: progress.completedFileCount, total: progress.totalFileCount)
                )
            case .failed,
                .ready:
                nil
            }

        guard let update else {
            return
        }
        setCurrentStep(
            id: update.id,
            title: update.title,
            detail: update.detail,
            fractionCompleted: update.fractionCompleted
        )
    }

    mutating func finish(succeeded: Bool) {
        completeRunningSteps()
        steps.append(
            EditorBuildStep(
                id: succeeded ? "completed" : "failed",
                title: succeeded ? "Completed" : "Failed",
                detail: nil,
                state: succeeded ? .completed : .failed,
                fractionCompleted: succeeded ? 1 : nil
            )
        )
    }

    private mutating func setCurrentStep(
        id: String,
        title: String,
        detail: String?,
        fractionCompleted: Float?
    ) {
        if let index = steps.lastIndex(where: { $0.id == id }) {
            steps[index].title = title
            steps[index].detail = Self.compactDetail(detail)
            steps[index].state = .running
            steps[index].fractionCompleted = fractionCompleted.map(Self.clampedFraction)
            return
        }

        completeRunningSteps()
        steps.append(
            EditorBuildStep(
                id: id,
                title: title,
                detail: Self.compactDetail(detail),
                state: .running,
                fractionCompleted: fractionCompleted.map(Self.clampedFraction)
            )
        )
    }

    private mutating func completeRunningSteps() {
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = .completed
        }
    }

    private static func stepUpdate(for rawLine: String) -> StepUpdate? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            return nil
        }

        let lowercasedLine = line.lowercased()
        if lowercasedLine.contains("planning build") {
            return StepUpdate(id: "planning", title: "Planning build")
        }
        if lowercasedLine.hasPrefix("fetching ")
            || lowercasedLine.hasPrefix("computing version for ")
            || lowercasedLine.hasPrefix("resolving ") {
            return StepUpdate(id: "dependencies", title: "Resolving dependencies", detail: line)
        }
        if lowercasedLine.contains("building for ") {
            return StepUpdate(id: "preparing-build", title: "Preparing build", detail: line)
        }
        if lowercasedLine.contains("compiling ") || lowercasedLine.contains("emitting module ") {
            return StepUpdate(
                id: "compiling",
                title: "Compiling sources",
                detail: Self.commandDetail(in: line),
                fractionCompleted: Self.bracketedFraction(in: line)
            )
        }
        if lowercasedLine.contains("copying ") {
            return StepUpdate(
                id: "resources",
                title: "Copying resources",
                detail: Self.commandDetail(in: line),
                fractionCompleted: Self.bracketedFraction(in: line)
            )
        }
        if lowercasedLine.contains("write sources") || lowercasedLine.contains("write objects.linkfilelist") {
            return StepUpdate(
                id: "generating",
                title: "Generating build inputs",
                detail: Self.commandDetail(in: line),
                fractionCompleted: Self.bracketedFraction(in: line)
            )
        }
        if lowercasedLine.contains("linking ") {
            return StepUpdate(
                id: "linking",
                title: "Linking",
                detail: Self.commandDetail(in: line),
                fractionCompleted: Self.bracketedFraction(in: line)
            )
        }
        if lowercasedLine.contains("build complete") {
            return StepUpdate(id: "finalizing", title: "Finalizing build", detail: line, fractionCompleted: 1)
        }
        return nil
    }

    private static func bracketedFraction(in line: String) -> Float? {
        guard line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let values = line[line.index(after: line.startIndex)..<closingBracket].split(separator: "/")
        guard values.count == 2, let completed = Int(values[0]), let total = Int(values[1]), total > 0 else {
            return nil
        }
        return clampedFraction(Float(completed) / Float(total))
    }

    private static func commandDetail(in line: String) -> String {
        guard line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") else {
            return line
        }
        return String(line[line.index(after: closingBracket)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func fraction(completed: Int?, total: Int?) -> Float? {
        guard let completed, let total, total > 0 else {
            return nil
        }
        return clampedFraction(Float(completed) / Float(total))
    }

    private static func clampedFraction(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func compactDetail(_ detail: String?) -> String? {
        let value = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            return nil
        }
        let firstLine = value.components(separatedBy: .newlines).first ?? value
        let limit = 160
        guard firstLine.count > limit else {
            return firstLine
        }
        return "\(firstLine.prefix(limit))…"
    }

    private struct StepUpdate {
        var id: String
        var title: String
        var detail: String?
        var fractionCompleted: Float?
    }
}
