@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSourceControlSidebar: View {
    let viewModel: EditorViewModel

    @Environment(\.metrics) private var metrics
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adaEditorPanelTitle("SOURCE CONTROL", trailing: viewModel.sourceControl.snapshot.branchTitle, theme: theme)
            HStack(spacing: 6) {
                tabButton("Changes (\(Set(viewModel.sourceControl.snapshot.files.map(\.path)).count))", active: !viewModel.sourceControl.showsHistory) {
                    viewModel.sourceControl.showsHistory = false
                }
                tabButton("History", active: viewModel.sourceControl.showsHistory) { viewModel.selectGitHistory() }
            }
            .padding(8)
            repositoryHeader.padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if viewModel.sourceControl.showsHistory {
                        historySection
                    } else {
                        HStack(spacing: 8) {
                            commandButton("View Diff") { viewModel.openGitDiff() }
                            GitStatisticsView(statistics: totalStatistics)
                            Spacer()
                        }
                        changeSections
                    }
                    commandButton(viewModel.sourceControl.showsRepositoryActions ? "⌄ Repository" : "› Repository") {
                        viewModel.sourceControl.showsRepositoryActions.toggle()
                    }
                    if viewModel.sourceControl.showsRepositoryActions {
                        actionSection
                        branchSection
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            if !viewModel.sourceControl.showsHistory {
                commitSection.padding(8)
            }
        }
        .background(
            RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner)
                .fill(theme.editorColors.surfaceElevated)
        )
        .mask(RoundedRectangleShape(cornerRadius: metrics.panelsRoundedCorner))
        .onAppear { viewModel.refreshSourceControl() }
        .accessibilityIdentifier("AdaEditor.Git.Sidebar")
    }

    private func tabButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(active ? theme.editorColors.text : theme.editorColors.muted)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(active ? theme.editorColors.blue.opacity(0.20) : Color.clear))
        }
        .buttonStyle(DefaultButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(title == "History" ? "AdaEditor.Git.History" : "AdaEditor.Git.Changes")
    }

    private var repositoryHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(viewModel.sourceControl.snapshot.branchTitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Spacer()
                commandButton("Refresh", enabled: !viewModel.sourceControl.isRunning) {
                    viewModel.refreshSourceControl()
                }
            }
            let trackingTitle = viewModel.sourceControl.snapshot.trackingTitle
            if !trackingTitle.isEmpty {
                Text(trackingTitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.blue)
                    .lineLimit(1)
            }
            Text(viewModel.sourceControl.commandError ?? viewModel.sourceControl.statusMessage)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(3)
            if shouldOfferGitRepositoryInitialization {
                commandButton("Create .git", enabled: !viewModel.sourceControl.isRunning) {
                    viewModel.createSourceControlRepository()
                }
            }
        }
        .padding(9)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
    }

    private var commitSection: some View {
        section("COMMIT") {
            TextField("Commit message", text: viewModel.sourceControl.commitMessageBinding)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
                .textFieldStyle(PlainTextFieldStyle())

            HStack(spacing: 8) {
                commandButton("Commit", enabled: viewModel.sourceControl.canCommit) {
                    viewModel.commitSourceControlChanges()
                }
                commandButton("Stage All", enabled: !viewModel.sourceControl.isRunning && viewModel.sourceControl.hasChanges) {
                    viewModel.stageAllSourceControlFiles()
                }
                commandButton("Unstage All", enabled: !viewModel.sourceControl.isRunning && !viewModel.sourceControl.snapshot.stagedFiles.isEmpty) {
                    viewModel.unstageAllSourceControlFiles()
                }
            }
        }
    }

    private var totalStatistics: GitDiffStatistics {
        let files = viewModel.sourceControl.snapshot.diffFiles
        return GitDiffStatistics(additions: files.reduce(0) { $0 + $1.statistics.additions }, deletions: files.reduce(0) { $0 + $1.statistics.deletions })
    }

    private var changeSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            fileSection("STAGED", comparison: .staged)
            fileSection("CHANGES", comparison: .workingTree)
            fileSection("UNTRACKED", comparison: .untracked)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVStack(viewModel.sourceControl.commits, alignment: .leading, spacing: 4, estimatedRowHeight: 58) { commit in
                Button(action: { viewModel.openGitDiff(commit: commit) }) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(commit.subject).font(.system(size: 12)).foregroundColor(theme.editorColors.text).lineLimit(2)
                        Text("\(commit.author) · \(relativeDate(commit.date)) · \(commit.shortID)")
                            .font(.system(size: 10)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                    }
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.surface))
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Git.Commit.\(commit.id)")
            }
            if viewModel.sourceControl.isLoadingHistory {
                emptyText("Loading history…")
            } else if let error = viewModel.sourceControl.historyError {
                emptyText(error)
                commandButton("Retry") { viewModel.loadGitHistory() }
            } else if viewModel.sourceControl.commits.isEmpty {
                emptyText("No commits yet.")
            }
            if viewModel.sourceControl.hasMoreHistory {
                commandButton("Load More", enabled: !viewModel.sourceControl.isLoadingHistory) { viewModel.loadGitHistory() }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "\(seconds / 3_600)h ago"
        }
        return "\(seconds / 86_400)d ago"
    }

    private var actionSection: some View {
        section("ACTIONS") {
            HStack(spacing: 8) {
                commandButton("Stash", enabled: !viewModel.sourceControl.isRunning && viewModel.sourceControl.hasChanges) {
                    viewModel.stashSourceControlChanges()
                }
                commandButton("Pull", enabled: !viewModel.sourceControl.isRunning) {
                    viewModel.pullSourceControlChanges()
                }
                commandButton("Push", enabled: !viewModel.sourceControl.isRunning) {
                    viewModel.pushSourceControlChanges()
                }
            }
        }
    }

    private var branchSection: some View {
        section("BRANCHES") {
            HStack(spacing: 8) {
                TextField("new-branch", text: viewModel.sourceControl.newBranchNameBinding)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
                    .textFieldStyle(PlainTextFieldStyle())
                commandButton("Create", enabled: viewModel.sourceControl.canCreateBranch) {
                    viewModel.createSourceControlBranch()
                }
            }

            if viewModel.sourceControl.snapshot.branches.isEmpty {
                emptyText("No local branches.")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.sourceControl.snapshot.branches, id: \.id) { branch in
                        branchRow(branch)
                    }
                }
            }
        }
    }

    private func fileSection(_ title: String, comparison: GitComparison) -> some View {
        let files = viewModel.sourceControl.snapshot.diffFiles.filter { $0.comparison == comparison }
        return section("\(title) \(files.count)") {
            if files.isEmpty {
                emptyText("No files.")
            } else {
                LazyVStack(files, alignment: .leading, spacing: 3, estimatedRowHeight: 44) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: GitDiffFile) -> some View {
        HStack(spacing: 5) {
            Button(action: { viewModel.openGitDiff(fileID: file.id) }) {
                HStack(spacing: 6) {
                    Text(file.status.rawValue).font(.system(size: 10)).foregroundColor(theme.editorColors.blue).frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.system(size: 11)).foregroundColor(theme.editorColors.text).lineLimit(1)
                        Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.directory)
                            .font(.system(size: 9)).foregroundColor(theme.editorColors.muted).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(DefaultButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("AdaEditor.Git.File.\(file.id)")
            VStack(alignment: .trailing, spacing: 2) {
                GitStatisticsView(statistics: file.statistics)
                commandButton(file.comparison == .staged ? "Unstage" : "Stage", enabled: !viewModel.sourceControl.isRunning) {
                    let command: GitCommandKind = file.comparison == .staged ? .unstage(paths: file.paths) : .stage(paths: file.paths)
                    viewModel.executeSourceControlCommand(command, statusTitle: "Update index: \(file.path)")
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 46)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface.opacity(0.58)))
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        Button(action: { viewModel.checkoutSourceControlBranch(branch) }) {
            HStack(spacing: 7) {
                Text(branch.isCurrent ? "*" : "")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.blue)
                    .frame(width: 12)
                Text(branch.name)
                    .font(.system(size: 11))
                    .foregroundColor(branch.isCurrent ? theme.editorColors.text : theme.editorColors.muted)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(branch.isCurrent ? theme.editorColors.blue.opacity(0.18) : Color.clear))
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(viewModel.sourceControl.isRunning || branch.isCurrent)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.blue)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(theme.editorColors.muted)
            .padding(.vertical, 2)
    }

    private func commandButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(enabled ? theme.editorColors.text : theme.editorColors.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(enabled ? 0.20 : 0.07)))
        }
        .buttonStyle(DefaultButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityIdentifier("AdaEditor.Git.\(title)")
    }

    private var shouldOfferGitRepositoryInitialization: Bool {
        guard !viewModel.sourceControl.isRunning, !viewModel.sourceControl.isRefreshing else {
            return false
        }
        guard viewModel.sourceControl.snapshot.rootURL == nil else {
            return false
        }
        let message = (viewModel.sourceControl.commandError ?? viewModel.sourceControl.statusMessage).lowercased()
        return message.contains("not a git repository")
    }
}
