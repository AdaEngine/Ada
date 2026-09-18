//
//  EditorBottomPanel.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 17.05.2026.
//

import AdaEngine
import Foundation

struct EditorBottomPanel: View {
    private enum ScrollTarget {
        static let top = "AdaEditor.Output.Top"
        static let bottom = "AdaEditor.Output.Bottom"
    }

    let viewModel: EditorViewModel
    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(metrics.outputTabs, id: \.self) { tab in
                        outputTab(tab)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 34)
            .background(theme.editorColors.surface)

            if viewModel.activeOutputTab == "Output" {
                HStack(spacing: 8) {
                    ForEach(["Game", "Editor"], id: \.self) { source in
                        commandButton(source) { viewModel.activeLogSource = source }
                            .foregroundColor(viewModel.activeLogSource == source ? theme.editorColors.text : theme.editorColors.muted)
                            .background(RoundedRectangleShape(cornerRadius: 5).fill(viewModel.activeLogSource == source ? theme.editorColors.blue.opacity(0.22) : .clear))
                            .accessibilityIdentifier("AdaEditor.Logs.Tab.\(source)")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if viewModel.activeOutputTab == "Performance" {
                EditorPerformancePanel(model: viewModel.performance)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        HStack(spacing: 0) {
                            ScrollView([.horizontal, .vertical]) {
                                VStack(alignment: .leading, spacing: 6) {
                                    RectangleShape()
                                        .fill(Color.clear)
                                        .frame(width: 1, height: 1)
                                        .id(ScrollTarget.top)
                                    panelContent
                                    RectangleShape()
                                        .fill(Color.clear)
                                        .frame(width: 1, height: 1)
                                        .id(ScrollTarget.bottom)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }

                            if showsOutputControls {
                                outputControlRail(proxy)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background {
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        }
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
    }

    @ViewBuilder
    private var panelContent: some View {
        switch viewModel.activeOutputTab {
        case "Problems":
            if viewModel.problems.isEmpty {
                outputLine("No problems. \(viewModel.workspaceStatus.title)")
            } else {
                problemLog
            }
        case "Build":
            commandButton("Build All") { viewModel.buildAll() }
            ForEach(viewModel.packageModel?.targets.map(\.name).sorted() ?? [], id: \.self) { target in
                commandButton("Build \(target)") { viewModel.buildTarget(target) }
            }
            if let activity = viewModel.buildActivity {
                outputSectionTitle(activity.title)
                ForEach(activity.steps) { step in
                    buildStepRow(step)
                }
            }
            outputSectionTitle("Build Output")
            outputLog
        case "Tests":
            commandButton("Run All Tests") { viewModel.runTests() }
            ForEach(viewModel.testTargets, id: \.self) { target in
                commandButton("Run \(target)") { viewModel.runTests(filter: target) }
            }
        case "References":
            if viewModel.symbolReferences.isEmpty {
                outputLine("No references.")
            } else {
                ForEach(viewModel.symbolReferences, id: \.self) { reference in
                    outputLine("\(reference.filePath):\(reference.range.start.line + 1):\(reference.range.start.character + 1)")
                }
            }
        default:
            outputLog
        }
    }

    private var outputLog: some View {
        LazyVStack(
            viewModel.activeOutputTab == "Output" && viewModel.activeLogSource == "Game" ? viewModel.gameLogLines : viewModel.outputLines,
            alignment: .leading,
            spacing: 6,
            estimatedRowHeight: 19,
            overscan: 12,
            reuseRowsWithStableIDs: true
        ) { line in
            outputLine(line.text, color: logColor(for: line.text))
        }
    }

    private var problemLog: some View {
        LazyVStack(
            viewModel.problems,
            id: \.self,
            alignment: .leading,
            spacing: 6,
            estimatedRowHeight: 19,
            overscan: 12,
            reuseRowsWithStableIDs: true
        ) { problem in
            outputLine(
                "\(problem.severity.rawValue.uppercased()) \(problem.filePath):\(problem.range.start.line + 1):\(problem.range.start.character + 1) \(problem.message)",
                color: diagnosticColor(for: problem.severity)
            )
        }
    }

    private func outputLine(_ line: String, color: Color? = nil) -> some View {
        Text(line)
            .font(.system(size: 13))
            .foregroundColor(color ?? logColor(for: line))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func outputSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .padding(.top, 8)
    }

    private func buildStepRow(_ step: EditorBuildStep) -> some View {
        HStack(spacing: 8) {
            Text(buildStepGlyph(for: step.state))
                .font(.system(size: 12))
                .foregroundColor(buildStepColor(for: step.state))
                .frame(width: 14)
            Text(step.title)
                .font(.system(size: 13))
                .foregroundColor(step.state == .running ? theme.editorColors.text : theme.editorColors.muted)
            if let detail = step.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            if let fractionCompleted = step.fractionCompleted {
                Text("\(Int((fractionCompleted * 100).rounded()))%")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.blue)
            }
        }
        .frame(height: 20)
        .accessibilityIdentifier("AdaEditor.BuildStep.\(step.id)")
    }

    private func buildStepGlyph(for state: EditorBuildStepState) -> String {
        switch state {
        case .completed:
            "✓"
        case .failed:
            "×"
        case .running:
            "●"
        }
    }

    private func buildStepColor(for state: EditorBuildStepState) -> Color {
        switch state {
        case .completed:
            Color(red: 110 / 255, green: 205 / 255, blue: 126 / 255)
        case .failed:
            Color(red: 245 / 255, green: 110 / 255, blue: 110 / 255)
        case .running:
            theme.editorColors.blue
        }
    }

    private func diagnosticColor(for severity: EditorDiagnosticSeverity) -> Color {
        switch severity {
        case .error:
            return Color(red: 245 / 255, green: 110 / 255, blue: 110 / 255)
        case .warning:
            return Color(red: 234 / 255, green: 192 / 255, blue: 102 / 255)
        case .information:
            return Color(red: 114 / 255, green: 180 / 255, blue: 255 / 255)
        case .hint:
            return theme.editorColors.purple.opacity(0.92)
        }
    }

    private func logColor(for line: String) -> Color {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedLine = trimmedLine.lowercased()

        if trimmedLine.hasPrefix("$ ") {
            return theme.editorColors.blue.opacity(0.88)
        }
        if lowercasedLine.hasPrefix("exited with code 0") || lowercasedLine.contains("succeeded") || lowercasedLine.contains("completed") {
            return Color(red: 110 / 255, green: 205 / 255, blue: 126 / 255)
        }
        if lowercasedLine.contains("error:") || lowercasedLine.hasPrefix("error") || lowercasedLine.contains(" failed") || lowercasedLine.hasPrefix("failed") {
            return Color(red: 245 / 255, green: 110 / 255, blue: 110 / 255)
        }
        if lowercasedLine.contains("warning:") || lowercasedLine.hasPrefix("warning") {
            return Color(red: 234 / 255, green: 192 / 255, blue: 102 / 255)
        }
        if lowercasedLine.hasPrefix("information") || lowercasedLine.hasPrefix("info") || lowercasedLine.hasPrefix("note:") || lowercasedLine.contains(" note:") {
            return Color(red: 114 / 255, green: 180 / 255, blue: 255 / 255)
        }
        if lowercasedLine.hasPrefix("debug") || lowercasedLine.hasPrefix("trace") {
            return theme.editorColors.purple.opacity(0.86)
        }
        if lowercasedLine.hasPrefix("exited with code") {
            return Color(red: 245 / 255, green: 110 / 255, blue: 110 / 255)
        }

        return theme.editorColors.muted
    }

    private func commandButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.blue)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
    }

    private func outputTab(_ tab: String) -> some View {
        let active = tab == viewModel.activeOutputTab

        return Button(action: { viewModel.selectOutputTab(tab) }) {
            Text(tab)
                .font(.system(size: 12))
                .foregroundColor(active ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, metrics.outputTabHorizontalPadding)
                .frame(width: outputTabWidth(tab), height: 24)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(active ? theme.editorColors.surfaceElevated : theme.editorColors.surface.opacity(0.55)))
                .overlay {
                    RoundedRectangleShape(cornerRadius: 5)
                        .stroke(active ? theme.editorColors.blue.opacity(0.68) : theme.editorColors.border.opacity(0.36), lineWidth: 1)
                }
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Output.Tab.\(tab)")
    }

    private func outputTabWidth(_ tab: String) -> Float {
        Float(tab.count) * 7 + metrics.outputTabHorizontalPadding * 2
    }

    private var showsOutputControls: Bool {
        viewModel.activeOutputTab == "Build" || viewModel.activeOutputTab == "Output"
    }

    private func outputControlRail(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            outputControlButton(
                glyph: "\u{E25A}",
                identifier: "AdaEditor.Output.ScrollToTop"
            ) {
                proxy.scrollTo(ScrollTarget.top, anchor: .top)
            }
            outputControlButton(
                glyph: "\u{E258}",
                identifier: "AdaEditor.Output.ScrollToBottom"
            ) {
                proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
            }
            RectangleShape()
                .fill(theme.editorColors.border.opacity(0.55))
                .frame(width: 20, height: 1)
            outputControlButton(
                glyph: "\u{E872}",
                identifier: "AdaEditor.Output.Clear"
            ) {
                viewModel.clearVisibleLog()
            }
            Spacer()
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .frame(width: 38)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.editorColors.surface.opacity(0.72))
    }

    private func outputControlButton(
        glyph: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(AdaEditorMaterialSymbolFont.font(size: 16))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(EditorOutputControlButtonStyle(theme: theme))
        .accessibilityIdentifier(identifier)
    }
}

private struct EditorOutputControlButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.state.isHighlighted ? theme.editorColors.text : theme.editorColors.muted)
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(configuration.state.isHighlighted ? theme.editorColors.surfaceElevated : Color.clear)
            )
    }
}
