import Foundation
import Observation

struct EditorTestItem: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable { case notRun = "Not run", running = "Running", passed = "Passed", failed = "Failed", skipped = "Skipped" }
    let id: String
    var name: String
    let filter: String
    var path: String = ""
    var line: Int = 1
    var status: Status = .notRun
    var detail: String = ""
    var exactSwiftFilter: String { "^" + NSRegularExpression.escapedPattern(for: filter) + "(?:/.*)?$" }
}

@MainActor @Observable
final class EditorTestExplorer {
    var items: [EditorTestItem] = []
    var isDiscovering = false
    var message: String?
    var isRunning = false
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private var project: URL?
    @ObservationIgnored private var pendingOutput = ""
    @ObservationIgnored private var reportURL: URL?
    @ObservationIgnored private var adaOutcomes: [String: EditorAdaScriptTestOutcome] = [:]
    @ObservationIgnored private let discoveryRunner = EditorProcessRunner()

    func stopDiscovery() {
        discovery?.cancel()
        discovery = nil
        isDiscovering = false
        let runner = discoveryRunner
        Task { await runner.cancelAll() }
    }

    func refresh(projectURL: URL?, service: any SwiftPMWorkspaceServicing) {
        guard !isDiscovering, !isRunning, let projectURL else { return }
        if project != projectURL { items = []; adaOutcomes = [:]; project = projectURL }
        isDiscovering = true
        message = nil
        discovery = Task { [weak self] in
            do {
                let settings = try ProjectSystem.loadProject(at: projectURL)
                let found: [EditorTestItem]
                if settings.build.system.isAdaScript {
                    found = try EditorAdaScriptTestRunner().discover(project: settings, at: projectURL)
                } else {
                    let toolchain = await SwiftToolchainLocator.locate()
                    var command = await service.makeCommand(.test(filter: nil), projectURL: projectURL, toolchain: toolchain)
                    command.arguments = ["test", "list"]
                    guard let runner = self?.discoveryRunner else { return }
                    let result = await runner.run(command)
                    guard result.succeeded else { throw DiscoveryError.failed(result.combinedOutput) }
                    found = Self.swiftTests(from: result.standardOutput)
                }
                guard let self, !Task.isCancelled else { return }
                let previous = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.items = found.map { item in
                    var item = item
                    item.status = previous[item.id]?.status ?? .notRun
                    item.detail = previous[item.id]?.detail ?? ""
                    if let outcome = self.adaOutcomes[item.path + ":" + String(item.line)] {
                        item.status = outcome.passed ? .passed : .failed
                        item.detail = outcome.diagnostics.joined(separator: "\n")
                    }
                    return item
                }
                self.isDiscovering = false
            } catch {
                self?.message = error.localizedDescription
                self?.isDiscovering = false
            }
        }
    }

    func begin(filter: String?, exactID: String? = nil) {
        isRunning = true
        pendingOutput = ""
        for index in items.indices where exactID.map({ items[index].id == $0 })
            ?? (filter == nil || items[index].filter.contains(filter ?? "")) {
            items[index].status = .running
            items[index].detail = ""
        }
    }

    func receive(_ outcome: EditorAdaScriptTestOutcome) {
        adaOutcomes[outcome.path + ":" + String(outcome.line)] = outcome
        for index in items.indices where items[index].path == outcome.path && items[index].line == outcome.line {
            items[index].status = outcome.passed ? .passed : .failed
            items[index].detail = outcome.diagnostics.joined(separator: "\n")
        }
    }

    /// XCTest and Swift Testing both stream terminal result lines; keep partial chunks until a newline.
    func consume(_ text: String) {
        guard isRunning else { return }
        let lines = (pendingOutput + text).components(separatedBy: .newlines)
        pendingOutput = lines.last ?? ""
        for line in lines.dropLast() {
            let passed = line.contains(" passed")
            let failed = line.contains(" failed")
            guard passed || failed else { continue }
            let matches = items.indices.filter { Self.matchesResult(line, item: items[$0]) }
            // Swift Testing's text output omits suite names; JSON events resolve ambiguous names.
            guard matches.count == 1, let index = matches.first else { continue }
            items[index].status = failed ? .failed : .passed
            items[index].detail = line
        }
    }

    func finish() {
        consume("\n")
        if let reportURL, let report = try? String(contentsOf: reportURL, encoding: .utf8) {
            consumeEvents(report)
            try? FileManager.default.removeItem(at: reportURL)
        }
        if let reportURL {
            let xmlURL = URL(fileURLWithPath: reportURL.path + ".xml")
            if let data = try? Data(contentsOf: xmlURL) {
                for result in EditorXCTestReport.read(data) {
                    guard let index = items.firstIndex(where: { $0.filter == result.id }) else { continue }
                    items[index].status = result.skipped ? .skipped : result.failed ? .failed : .passed
                    items[index].detail = result.detail
                }
                try? FileManager.default.removeItem(at: xmlURL)
            }
        }
        reportURL = nil
        isRunning = false
        // A build failure or cancellation is not evidence that an unexecuted test failed or passed.
        for index in items.indices where items[index].status == .running { items[index].status = .notRun }
    }

    static func matchesResult(_ line: String, item: EditorTestItem) -> Bool {
        let parts = item.filter.split(separator: "/", maxSplits: 1).map(String.init)
        guard let function = parts.last else { return false }
        if line.contains("Test Case") {
            let suite = parts.first?.split(separator: ".").last.map(String.init) ?? ""
            return line.contains(suite + " " + function.replacingOccurrences(of: "()", with: ""))
                || line.contains(suite + "." + function.replacingOccurrences(of: "()", with: ""))
        }
        return line.contains("Test " + function + " ") || line.contains("Test \"" + item.name + "\"")
    }

    func prepareSwiftReport() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ada-test-events-\(UUID().uuidString).jsonl")
        reportURL = url
        return url
    }

    /// Swift Testing's version 0 event stream identifies suites and overloaded functions unambiguously.
    func consumeEvents(_ report: String) {
        for line in report.split(whereSeparator: \.isNewline) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else { continue }
            let id = payload["testID"] as? String ?? payload["id"] as? String ?? ""
            guard let index = items.firstIndex(where: { id == $0.filter || id.hasPrefix($0.filter + "/") }) else { continue }
            let messages = payload["messages"] as? [[String: Any]] ?? []
            if record["kind"] as? String == "test" {
                let location = payload["sourceLocation"] as? [String: Any]
                items[index].path = location?["filePath"] as? String ?? location?["_filePath"] as? String ?? ""
                items[index].line = location?["line"] as? Int ?? 1
                if let displayName = payload["displayName"] as? String { items[index].name = displayName }
            } else if payload["kind"] as? String == "testEnded" {
                items[index].status = messages.contains { $0["symbol"] as? String == "fail" } ? .failed : .passed
                items[index].detail += messages.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if payload["kind"] as? String == "issueRecorded" {
                items[index].detail += messages.compactMap { $0["text"] as? String }.joined(separator: "\n") + "\n"
            } else if payload["kind"] as? String == "testSkipped" {
                items[index].status = .skipped
            }
        }
    }

    static func swiftTests(from output: String) -> [EditorTestItem] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Build progress and diagnostics go to stderr; still reject non-specifier lines.
            guard !id.contains(" "), id.contains("."), id.contains("/") || id.hasSuffix(")") else { return nil }
            let name = id.split(separator: "/").last.map(String.init) ?? id
            return EditorTestItem(id: id, name: id.contains("/") ? name : String(name.split(separator: ".").last ?? ""), filter: id)
        }
    }

    private enum DiscoveryError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case let .failed(message) = self { message } else { nil } }
    }
}
