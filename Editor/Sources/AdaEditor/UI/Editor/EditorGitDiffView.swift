@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorGitDiffView: View {
    let document: EditorGitDocument
    let workbench: EditorWorkbenchViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            commitDetails
            if document.isLoading {
                notice("Loading commit…")
            } else if let message = document.message {
                notice(message)
            }
            GeometryReader { geometry in
                let width = max(geometry.size.width, contentWidth)
                ScrollView(.horizontal) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(document.rows, alignment: .leading, spacing: 0, estimatedRowHeight: 24) { row in
                                diffRow(row, width: width)
                                    .id(row.id)
                            }
                        }
                        .frame(width: width, height: geometry.size.height)
                        .onAppear { scroll(using: proxy) }
                        .onChange(of: document.scrollRevision) { _, _ in scroll(using: proxy) }
                        .onChange(of: document.rows.count) { _, _ in scroll(using: proxy) }
                    }
                }
            }
        }
        .foregroundColor(theme.editorColors.text)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.Git.Diff")
    }

    @ViewBuilder
    private var commitDetails: some View {
        if let commit = document.commit {
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.message).font(.system(size: 12)).lineLimit(4)
                Text("\(commit.author) · \(commit.date.formatted()) · \(commit.id)")
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                Text(commit.comparisonTitle).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }
            .padding(10)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            action("Split", selected: document.isSplit) { document.isSplit = true }
            action("Unified", selected: !document.isSplit) { document.isSplit = false }
            Spacer()
            GitStatisticsView(statistics: document.statistics)
            action("Previous") { document.navigateHunk(-1) }
            action("Next") { document.navigateHunk(1) }
        }
        .padding(8)
        .background(theme.editorColors.surface)
    }

    private var contentWidth: Float {
        let maximum = document.rows.reduce(60) { current, row in
            if case let .line(old, new) = row.content {
                return max(current, old?.text.count ?? 0, new?.text.count ?? 0)
            }
            return current
        }
        let column = Float(maximum) * Float(workbench.codeFontSize) * 0.65 + 110
        return document.isSplit ? column * 2 : column
    }

    private func scroll(using proxy: ScrollViewProxy) {
        if let target = document.scrollTarget {
            proxy.scrollTo(target, anchor: .topLeading)
        }
    }

    @ViewBuilder
    private func diffRow(_ row: EditorGitRow, width: Float) -> some View {
        switch row.content {
        case let .file(file):
            HStack(spacing: 8) {
                Button(
                    action: { document.toggle(file) },
                    label: {
                        HStack(spacing: 8) {
                            Text(document.expandedFiles.contains(file.id) ? "−" : "+").frame(width: 14)
                            Text("\(file.comparison.title) · \(file.path)").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 12))
                    }
                )
                .buttonStyle(DefaultButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("AdaEditor.Git.Diff.File.\(file.id)")
                GitStatisticsView(statistics: file.statistics)
                if let url = document.workingFileURL(file) {
                    action("Open File") { document.onOpenFile?(url) }
                }
                if !file.comparison.isHistorical {
                    action(file.comparison == .staged ? "Unstage" : "Stage") { document.onStage?(file) }
                        .disabled(document.isRunningCommand)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 36, alignment: .leading)
            .background(theme.editorColors.surfaceElevated)
        case let .message(message):
            notice(message).frame(width: width, alignment: .leading)
        case let .hunk(header):
            Text(header)
                .font(AdaEditorCodeFont.font(size: workbench.codeFontSize))
                .foregroundColor(theme.editorColors.muted)
                .padding(.horizontal, 10)
                .frame(width: width, height: 26, alignment: .leading)
                .background(theme.editorColors.blue.opacity(0.10))
                .accessibilityIdentifier("AdaEditor.Git.Diff.Hunk.\(row.id)")
        case let .line(old, new):
            HStack(spacing: 0) {
                if document.isSplit {
                    codeLine(old, oldSide: true, file: row.file, width: width / 2)
                    codeLine(new, oldSide: false, file: row.file, width: width / 2)
                } else {
                    codeLine(new, oldSide: false, file: row.file, width: width)
                }
            }
        }
    }

    private func codeLine(_ line: GitDiffLine?, oldSide: Bool, file: GitDiffFile, width: Float) -> some View {
        let font = AdaEditorCodeFont.font(family: workbench.codeFontFamily, weight: workbench.codeFontWeight, size: workbench.codeFontSize)
        return HStack(spacing: 8) {
            Text(lineNumber(line, oldSide: oldSide))
                .font(font)
                .foregroundColor(theme.editorColors.muted)
                .frame(width: document.isSplit ? 52 : 96, alignment: .trailing)
            Text(line?.kind == .addition ? "+" : line?.kind == .deletion ? "−" : " ")
                .font(font)
                .foregroundColor(line?.kind == .addition ? GitDiffColors.addition : line?.kind == .deletion ? GitDiffColors.deletion : theme.editorColors.muted)
                .frame(width: 12)
            Text(
                EditorSourceHoverPresentation.attributedText(
                    line?.text ?? "",
                    language: .detect(fileName: file.name),
                    palette: workbench.codeColorPalette,
                    font: font,
                    keywordFont: AdaEditorCodeFont.font(family: workbench.codeFontFamily, weight: workbench.keywordFontWeight, size: workbench.codeFontSize)
                )
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            Spacer()
        }
        .frame(width: width, height: max(24, Float(workbench.codeFontSize) * 1.6), alignment: .leading)
        .background(lineBackground(line))
    }

    private func lineNumber(_ line: GitDiffLine?, oldSide: Bool) -> String {
        guard let line else {
            return ""
        }
        if document.isSplit {
            return (oldSide ? line.oldNumber : line.newNumber).map(String.init) ?? ""
        }
        return "\(line.oldNumber.map(String.init) ?? "")  \(line.newNumber.map(String.init) ?? "")"
    }

    private func lineBackground(_ line: GitDiffLine?) -> Color {
        guard let line else {
            return theme.editorColors.muted.opacity(0.06)
        }
        switch line.kind {
        case .addition: return GitDiffColors.addition.opacity(0.13)
        case .deletion: return GitDiffColors.deletion.opacity(0.13)
        case .context,
            .note:
            return .clear
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundColor(theme.editorColors.muted).padding(10)
    }

    private func action(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(selected ? theme.editorColors.blue.opacity(0.25) : theme.editorColors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Git.Diff.\(title)")
    }
}

struct GitStatisticsView: View {
    let statistics: GitDiffStatistics
    var body: some View {
        HStack(spacing: 5) {
            if statistics.isBinary {
                Text("Binary").font(.system(size: 10))
            } else {
                Text("+\(statistics.additions)").font(.system(size: 10)).foregroundColor(GitDiffColors.addition)
                Text("−\(statistics.deletions)").font(.system(size: 10)).foregroundColor(GitDiffColors.deletion)
            }
        }
    }
}

private enum GitDiffColors {
    static let addition = Color(red: 154 / 255, green: 199 / 255, blue: 106 / 255)
    static let deletion = Color(red: 234 / 255, green: 128 / 255, blue: 115 / 255)
}
