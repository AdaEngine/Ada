import CEditorTerminal
import Foundation
import Observation
import SwiftTerm

/// One shell session. All terminal state and PTY access belong to the main actor.
@MainActor @Observable
final class EditorTerminalSession: Identifiable, @preconcurrency SwiftTerm.TerminalDelegate {
    let id = UUID()
    var title = "Terminal"
    var error: String?
    var isRunning = false
    @ObservationIgnored lazy var terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 24, scrollback: 5000))
    @ObservationIgnored lazy var selection = SelectionService(terminal: terminal)
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var process: OpaquePointer?
    @ObservationIgnored private var polling: Task<Void, Never>?
    // The opaque handle has one owner; all access and teardown run on this actor.
    @ObservationIgnored private var readBuffer = [UInt8](repeating: 0, count: 32768)
    @ObservationIgnored private var input: [UInt8] = []
    @ObservationIgnored private var inputOffset = 0
    @ObservationIgnored private var directory: URL?

    isolated deinit {
        polling?.cancel()
        if let process { ada_terminal_close(process) }
    }

    func start(in directory: URL) {
        guard process == nil else { return }
        self.directory = directory
        error = nil
        var message = [CChar](repeating: 0, count: 1024)
        process = directory.path.withCString { path in
            ada_terminal_open(path, Int32(terminal.cols), Int32(terminal.rows), &message, message.count)
        }
        guard process != nil else {
            error = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return
        }
        isRunning = true
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        if let process { ada_terminal_close(process) }
        process = nil
        input.removeAll()
        inputOffset = 0
        isRunning = false
    }

    func restart() {
        stop()
        terminal.resetToInitialState()
        if let directory { start(in: directory) }
        onChange?()
    }

    func resize(columns: Int, rows: Int) {
        let columns = max(2, min(500, columns)), rows = max(1, min(300, rows))
        guard terminal.cols != columns || terminal.rows != rows else { return }
        terminal.resize(cols: columns, rows: rows)
        if let process { _ = ada_terminal_resize(process, Int32(columns), Int32(rows)) }
        onChange?()
    }

    func send(_ text: String) { send(source: terminal, data: Array(text.utf8)[...]) }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard isRunning else { return }
        input.append(contentsOf: data)
    }

    func setTerminalTitle(source: Terminal, title: String) { self.title = title }

    private func poll() {
        guard let process else { return }
        let count = ada_terminal_read(process, &readBuffer, Int32(readBuffer.count))
        if count > 0 {
            terminal.feedPreservingSelection(readBuffer.prefix(Int(count)), selection: selection)
            onChange?()
        } else if count < 0 {
            stop()
            onChange?()
            return
        }
        if !input.isEmpty {
            let count = input.withUnsafeBufferPointer { buffer in
                ada_terminal_write(process, buffer.baseAddress?.advanced(by: inputOffset), Int32(min(1024, buffer.count - inputOffset)))
            }
            if count > 0 {
                inputOffset += Int(count)
                if inputOffset == input.count { input.removeAll(keepingCapacity: true); inputOffset = 0 }
            }
            if count < 0 { stop(); onChange?() }
        }
    }
}
