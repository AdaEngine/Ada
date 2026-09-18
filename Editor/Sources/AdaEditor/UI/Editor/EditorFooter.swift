@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorActivityKind: Equatable, Sendable {
    case agent
    case build
    case indexing
    case preview
    case run
    case sourceControl
    case test
    case workspace
}

struct EditorActivityEvent: Equatable, Sendable, Identifiable {
    let id: String
    let kind: EditorActivityKind
    let title: String
    let detail: String?
    let fractionCompleted: Float?

    init(
        id: String,
        kind: EditorActivityKind,
        title: String,
        detail: String? = nil,
        fractionCompleted: Float? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
    }

    var statusTitle: String {
        guard let fractionCompleted else {
            return title
        }
        return "\(title) · \(Int((fractionCompleted * 100).rounded()))%"
    }

    var displayTitle: String {
        let value = detail.map { "\(title) · \($0)" } ?? title
        guard let fractionCompleted else {
            return value
        }
        return "\(value) · \(Int((fractionCompleted * 100).rounded()))%"
    }

    var compactTitle: String {
        let title: String =
            switch kind {
            case .agent:
                "Agent"
            case .build:
                "Build"
            case .indexing:
                "Indexing"
            case .preview:
                "Preview"
            case .run:
                "Running"
            case .sourceControl:
                "Git"
            case .test:
                "Testing"
            case .workspace:
                "Preparing"
            }

        guard let fractionCompleted else {
            return title
        }
        return "\(title) · \(Int((fractionCompleted * 100).rounded()))%"
    }
}

@MainActor
enum EditorActivityPresentation {
    static func events(
        workspaceStatus: EditorWorkspaceStatus,
        buildActivity: EditorBuildActivity? = nil,
        previewStatus: EditorPreviewStatus,
        sourceControlIsRunning: Bool,
        sourceControlTitle: String
    ) -> [EditorActivityEvent] {
        var events = workspaceEvent(for: workspaceStatus, buildActivity: buildActivity).map { [$0] } ?? []

        if case let .building(declaration, message) = previewStatus {
            events.append(
                EditorActivityEvent(
                    id: "preview",
                    kind: .preview,
                    title: "Building preview \(declaration.title)",
                    detail: message
                )
            )
        }

        if sourceControlIsRunning {
            events.append(
                EditorActivityEvent(
                    id: "source-control",
                    kind: .sourceControl,
                    title: sourceControlTitle
                )
            )
        }

        return events
    }

    private static func workspaceEvent(
        for status: EditorWorkspaceStatus,
        buildActivity: EditorBuildActivity?
    ) -> EditorActivityEvent? {
        switch status {
        case .resolving:
            return EditorActivityEvent(
                id: "workspace",
                kind: .workspace,
                title: "Resolving SwiftPM dependencies"
            )
        case .indexing:
            return EditorActivityEvent(
                id: "workspace",
                kind: .indexing,
                title: "Indexing Swift package"
            )
        case let .preparing(progress):
            guard progress.phase != .ready, progress.phase != .failed else {
                return nil
            }
            let fractionCompleted: Float? =
                if let completed = progress.completedFileCount,
                    let total = progress.totalFileCount,
                    total > 0 {
                    Float(completed) / Float(total)
                } else {
                    nil
                }
            return EditorActivityEvent(
                id: "workspace",
                kind: progress.phase == .indexingBuild ? .indexing : .workspace,
                title: progress.title,
                detail: progress.currentTarget ?? progress.currentFile ?? progress.detail,
                fractionCompleted: fractionCompleted
            )
        case let .running(title):
            let step = buildActivity?.currentStep
            return EditorActivityEvent(
                id: "workspace-command",
                kind: commandKind(for: title),
                title: title,
                detail: step.map { $0.detail ?? $0.title },
                fractionCompleted: step?.fractionCompleted
            )
        case .cancelled,
            .failed,
            .idle,
            .ready:
            return nil
        }
    }

    private static func commandKind(for title: String) -> EditorActivityKind {
        let normalizedTitle = title.lowercased()
        if normalizedTitle.hasPrefix("build") {
            return .build
        }
        if normalizedTitle.hasPrefix("test") {
            return .test
        }
        if normalizedTitle.hasPrefix("run") || normalizedTitle.hasPrefix("play") {
            return .run
        }
        return .workspace
    }
}

struct EditorFooter: View {
    let viewModel: EditorFooterViewModel
    let activities: [EditorActivityEvent]
    var onOpenActivity: () -> Void = {}

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            ForEach(viewModel.leftItems, id: \.self) {
                Text($0)
            }
            Spacer()
            if metrics.showsFooterRight {
                ForEach(viewModel.rightItems, id: \.self) {
                    Text($0)
                }
            }
            if let activity = activities.first {
                Button(action: onOpenActivity) {
                    EditorActivityProgressView(
                        activity: activity,
                        additionalActivityCount: max(0, activities.count - 1),
                        width: metrics.size.width < 900 ? 260 : 420
                    )
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Activity.Open")
            }
        }
        .font(.system(size: 12))
        .foregroundColor(theme.editorColors.text)
        .padding(.horizontal, 10)
        .frame(height: metrics.footerHeight)
    }
}

private struct EditorActivityProgressView: View {
    let activity: EditorActivityEvent
    let additionalActivityCount: Int
    let width: Float

    @Environment(\.theme) private var theme

    var body: some View {
        let progressWidth = width < 300 ? Float(84) : Float(150)
        let countWidth = additionalActivityCount > 0 ? Float(28) : Float(0)
        let titleWidth = max(100, width - progressWidth - countWidth - 16)

        HStack(spacing: 8) {
            Text(activity.compactTitle)
                .lineLimit(1)
                .frame(width: titleWidth, alignment: .trailing)

            EditorActivityProgressBar(
                fractionCompleted: activity.fractionCompleted,
                width: progressWidth
            )

            if additionalActivityCount > 0 {
                Text("+\(additionalActivityCount)")
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: countWidth)
            }
        }
        .frame(width: width, height: 22, alignment: .trailing)
        .accessibilityIdentifier("AdaEditor.ActivityProgress")
    }
}

private struct EditorActivityProgressBar: View {
    let fractionCompleted: Float?
    let width: Float

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(anchor: .leading) {
            RoundedRectangleShape(cornerRadius: 1)
                .fill(theme.editorColors.border.opacity(0.55))
                .frame(width: width, height: 3)

            if let fractionCompleted {
                RoundedRectangleShape(cornerRadius: 1)
                    .fill(theme.editorColors.blue)
                    .frame(width: width * fractionCompleted, height: 3)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
                    let segmentWidth = width * 0.32
                    RoundedRectangleShape(cornerRadius: 1)
                        .fill(theme.editorColors.blue)
                        .frame(width: segmentWidth, height: 3)
                        .offset(x: (width + segmentWidth) * phase - segmentWidth)
                }
                .frame(width: width, height: 3)
                .mask(RectangleShape())
            }
        }
        .frame(width: width, height: 3)
        .accessibilityIdentifier("AdaEditor.ActivityProgress.Bar")
    }
}
