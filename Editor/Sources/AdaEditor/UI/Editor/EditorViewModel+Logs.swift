@_spi(AdaEngine) import AdaEngine

extension EditorViewModel {
    func appendGameLog(_ lines: [String]) {
        gameLogLines = EditorWorkspaceLogBuffer.appending(lines, to: gameLogLines)
    }

    func collectRuntimeLogs(store: RuntimeLogStore = .shared) {
        let batch = store.read(after: runtimeLogCursor, limit: 1000)
        runtimeLogCursor = batch.nextCursor
        var game: [String] = []
        var editor: [String] = []
        for entry in batch.entries {
            let line = "\(entry.level.uppercased()) [\(entry.label)] \(entry.message)"
            if entry.source == "Game" {
                game.append(line)
            } else {
                editor.append(line)
            }
        }
        if !game.isEmpty {
            appendGameLog(game)
        }
        if !editor.isEmpty {
            appendOutput(editor)
        }
    }

    func clearVisibleLog() {
        collectRuntimeLogs()
        if activeOutputTab == "Output" && activeLogSource == "Game" {
            gameLogLines.removeAll()
        } else {
            clearOutput()
        }
    }
}
