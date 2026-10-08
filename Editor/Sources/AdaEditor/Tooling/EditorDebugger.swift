import AdaDebugging
import CryptoKit
import Foundation
import Observation

enum EditorDebugLanguage: String, CaseIterable {
    case swift = "Swift / LLDB"
    case adaScript = "AdaScript"
}

@Observable
@MainActor
final class EditorDebugger {
    let swift = DebugSession()
    let adaScript = DebugSession()
    var selectedLanguage: EditorDebugLanguage = .swift
    var breakpoints: [SourceBreakpoint] = []
    var command = ""
    var watchExpression = ""
    var watches: [String] = []
    var isBuilding = false
    var isStopping = false
    var status = ""
    var modifiedSources = Set<String>()
    @ObservationIgnored var projectURL: URL?
    @ObservationIgnored var buildTask: Task<Void, Never>?
    @ObservationIgnored var buildGeneration = 0
    @ObservationIgnored let buildRunner = EditorProcessRunner()
    @ObservationIgnored var sourceContents: [String: String] = [:]
    @ObservationIgnored var launchedBreakpoints: [SourceBreakpoint] = []
    @ObservationIgnored private var breakpointTask: Task<Void, Never>?
    @ObservationIgnored private var storageURL: URL?

    var session: DebugSession { selectedLanguage == .swift ? swift : adaScript }
    var isActive: Bool { isBuilding || isStopping || swift.state.isActive || adaScript.state.isActive }

    func configure(projectURL: URL?, storageURL: URL? = nil) {
        self.projectURL = projectURL
        guard let projectURL else {
            return
        }
        let digest = SHA256.hash(data: Data(projectURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.storageURL =
            storageURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AdaEditor/Debugging/\(digest).json")
        guard let url = self.storageURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
            breakpoints = saved.breakpoints.filter { $0.line > 0 }
                .map { breakpoint in
                    var result = breakpoint
                    if !result.path.hasPrefix("/") {
                        result.path = projectURL.appendingPathComponent(result.path).standardizedFileURL.path
                    }
                    return result
                }
            watches = saved.watches
        } catch { status = "Cannot restore debugger state: \(error.localizedDescription)" }
    }

    func toggleBreakpoint(path: String, line: Int) {
        guard line > 0 else {
            return
        }
        if let index = breakpoints.firstIndex(where: { $0.path == path && $0.line == line }) {
            breakpoints.remove(at: index)
        } else {
            breakpoints.append(SourceBreakpoint(path: path, line: line))
        }
        persistAndSynchronize()
    }

    func setBreakpointEnabled(_ breakpoint: SourceBreakpoint, enabled: Bool) {
        guard let index = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else {
            return
        }
        breakpoints[index].enabled = enabled
        persistAndSynchronize()
    }

    func addWatch() {
        let expression = watchExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !watches.contains(expression) else {
            return
        }
        watches.append(expression)
        watchExpression = ""
        updateWatches()
    }

    func removeWatch(_ expression: String) {
        watches.removeAll { $0 == expression }
        updateWatches()
    }

    func sendCommand() {
        let text = command
        command = ""
        let target = session
        Task { await target.executeConsole(text) }
    }

    func stop() {
        guard !isStopping else {
            return
        }
        buildGeneration += 1
        buildTask?.cancel()
        buildTask = nil
        isBuilding = false
        breakpointTask?.cancel()
        isStopping = true
        Task {
            await buildRunner.cancelAll()
            await swift.stop()
            await adaScript.stop()
            isStopping = false
        }
    }

    func sourceChanged(path: String, text: String) {
        defer { sourceContents[path] = text }
        guard let old = sourceContents[path], old != text else {
            return
        }
        if isActive {
            modifiedSources.insert(path)
        }
        breakpoints = DebugSourceEdits.relocate(breakpoints, path: path, old: old, new: text)
        // The running binary still uses the saved source snapshot.
        if isActive {
            save()
        } else {
            persistAndSynchronize()
        }
    }

    func save() {
        guard let storageURL else {
            return
        }
        do {
            let root = projectURL?.standardizedFileURL.path
            let relative = breakpoints.map { breakpoint in
                var result = breakpoint
                if let root, result.path.hasPrefix(root + "/") {
                    result.path = String(result.path.dropFirst(root.count + 1))
                }
                return result
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(SavedState(breakpoints: relative, watches: watches))
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch { status = "Cannot save debugger state: \(error.localizedDescription)" }
    }

    private func persistAndSynchronize() {
        save()
        let retained = launchedBreakpoints.filter { modifiedSources.contains($0.path) }
            .compactMap { original -> SourceBreakpoint? in
                guard let current = breakpoints.first(where: { $0.id == original.id }) else {
                    return nil
                }
                var point = original
                point.enabled = current.enabled
                return point
            }
        let current = breakpoints.filter { !modifiedSources.contains($0.path) } + retained
        let previous = breakpointTask
        breakpointTask = Task { [weak self] in
            // Keep replace-all setBreakpoints requests ordered while editing quickly.
            await previous?.value
            guard !Task.isCancelled, let self else {
                return
            }
            await self.swift.setBreakpoints(current.filter { URL(fileURLWithPath: $0.path).pathExtension == "swift" })
            await self.adaScript.setBreakpoints(current.filter { URL(fileURLWithPath: $0.path).pathExtension != "swift" })
        }
    }

    private func updateWatches() {
        swift.watches = watches
        adaScript.watches = watches
        save()
        Task { await session.refreshWatches() }
    }

    private struct SavedState: Codable {
        var breakpoints: [SourceBreakpoint]
        var watches: [String]
    }
}
