import AdaScriptCompilerCore
import Foundation

extension EditorViewModel {
    /// Runs the `@test` functions of an AdaScript project in-process and streams results to the Output panel.
    ///
    /// Results are also kept in ``adaScriptTestSummary`` so `editor.task.status` can report counts.
    func runAdaScriptTests(
        _ settings: AdaProject,
        at projectURL: URL,
        filter: String?,
        exactName: String? = nil,
        testTimeout: Duration = EditorAdaScriptTestRunner.defaultTestTimeout
    ) {
        guard workspaceTask == nil else { return }
        let statusTitle = "Test"
        let notificationRunID = beginWorkspaceActivity(title: statusTitle, source: .test, supportsCancellation: false)
        workspaceOutputIsGame = false
        workspaceStatus = .running(statusTitle)
        footer.setWorkspaceFooterTitle(workspaceStatus.title)
        adaScriptTestSummary = EditorAdaScriptTestSummary(passed: 0, failed: 0, filter: filter, outcomes: [], finished: false)
        appendOutput("$ AdaScript tests" + (filter.map { " --filter \($0)" } ?? "") + " (SwiftPM disabled)")

        let (stream, continuation) = AsyncStream<EditorAdaScriptTestOutcome>.makeStream()
        let runner = Task.detached(priority: .userInitiated) { () -> Result<[EditorAdaScriptTestOutcome], EditorAdaScriptTestError> in
            defer { continuation.finish() }
            do throws(EditorAdaScriptTestError) {
                return .success(
                    try EditorAdaScriptTestRunner().run(
                        project: settings,
                        at: projectURL,
                        filter: filter,
                        exactName: exactName,
                        testTimeout: testTimeout,
                        onResult: { continuation.yield($0) }
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        workspaceTask = Task { [weak self] in
            for await outcome in stream {
                guard let self, !Task.isCancelled else { break }
                self.receiveAdaScriptTestOutcome(outcome)
            }
            let result = await runner.value
            guard !Task.isCancelled, let self else { return }
            self.workspaceTask = nil
            self.tests.finish()
            switch result {
            case let .success(outcomes):
                let failed = outcomes.filter { !$0.passed }.count
                let line = EditorAdaScriptTestRunner.summaryLine(passed: outcomes.count - failed, failed: failed)
                self.adaScriptTestSummary?.finished = true
                self.appendOutput(line)
                self.buildActivity = nil
                self.workspaceStatus = failed == 0 ? .ready : .failed(line)
                self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                self.finishWorkspaceActivity(notificationRunID, succeeded: failed == 0, detail: failed == 0 ? line : self.failureDetail(of: outcomes))
                if failed > 0, self.activeOutputTab != "Tests" { self.showProblemsIfNeeded() }
            case let .failure(error):
                let message = error.errorDescription ?? "AdaScript tests failed."
                self.adaScriptTestSummary = nil
                self.appendOutput(message)
                self.buildActivity = nil
                self.workspaceStatus = .failed(message)
                self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
                self.finishWorkspaceActivity(notificationRunID, succeeded: false, detail: message)
            }
        }
    }

    private func receiveAdaScriptTestOutcome(_ outcome: EditorAdaScriptTestOutcome) {
        tests.receive(outcome)
        adaScriptTestSummary?.outcomes.append(outcome)
        if outcome.passed {
            adaScriptTestSummary?.passed += 1
        } else {
            adaScriptTestSummary?.failed += 1
        }
        appendOutput(EditorAdaScriptTestRunner.lines(for: outcome))
    }

    private func failureDetail(of outcomes: [EditorAdaScriptTestOutcome]) -> String {
        outcomes.filter { !$0.passed }.flatMap(EditorAdaScriptTestRunner.lines(for:)).joined(separator: "\n")
    }
}
