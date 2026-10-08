import Foundation
import Observation

public protocol DebugTransport: Sendable {
    var events: AsyncStream<DebugJSON> { get }
    func request(_ command: String, arguments: [String: DebugJSON], timeout: Duration) async throws -> DebugJSON
    func disconnect() async
}

#if os(macOS)
extension LLDBDebugClient: DebugTransport {}
#endif

public enum DebugSessionState: String, Sendable {
    case idle, starting, running, paused, stopping, terminated, failed

    public var isActive: Bool { self == .starting || self == .running || self == .paused || self == .stopping }
}

public struct SourceBreakpoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    /// One-based source line. Conversion to editor coordinates happens at the UI boundary.
    public var line: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), path: String, line: Int, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.line = line
        self.enabled = enabled
    }
}

public struct DebugStackFrame: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let path: String?
    public let line: Int
    public let column: Int

    init(_ value: DebugJSON) {
        id = value["id"].int ?? 0
        name = value["name"].string ?? "<unknown>"
        path = value["source"]["path"].string
        line = value["line"].int ?? 1
        column = value["column"].int ?? 1
    }
}

public struct DebugVariable: Equatable, Sendable {
    public let name: String
    public let value: String
    public let type: String?
    public let reference: Int
    public let memoryReference: String?

    init(_ data: DebugJSON) {
        name = data["name"].string ?? ""
        value = data["value"].string ?? ""
        type = data["type"].string
        reference = data["variablesReference"].int ?? 0
        memoryReference = data["memoryReference"].string
    }
}

/// UI state for one debugger. Each stop invalidates frame and value references.
@Observable
@MainActor
public final class DebugSession {
    public private(set) var state: DebugSessionState = .idle
    public private(set) var reason = ""
    public private(set) var frames: [DebugStackFrame] = []
    public private(set) var variables: [DebugVariable] = []
    public private(set) var selectedFrameID: Int?
    public private(set) var console: [String] = []
    public private(set) var verifiedBreakpoints: [UUID: Bool] = [:]
    public private(set) var breakpointMessages: [UUID: String] = [:]
    public private(set) var watchValues: [String: String] = [:]
    public private(set) var threads: [(id: Int, name: String)] = []
    public private(set) var threadID: Int?
    public private(set) var stopGeneration = 0
    public var watches: [String] = []
    @ObservationIgnored public var onSelectFrame: (@MainActor (DebugStackFrame) -> Void)?
    @ObservationIgnored public var onStopped: (@MainActor () -> Void)?
    @ObservationIgnored private var transport: (any DebugTransport)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var breakpoints: [SourceBreakpoint] = []
    @ObservationIgnored private var installedPaths = Set<String>()
    @ObservationIgnored private var breakpointIDs: [Int: UUID] = [:]
    @ObservationIgnored private var sessionGeneration = 0

    public init() {}

    public func launch(transport: any DebugTransport, arguments: [String: DebugJSON], breakpoints: [SourceBreakpoint]) async {
        guard !state.isActive else { return }
        if self.transport != nil || cleanupTask != nil { await stop() }
        sessionGeneration += 1
        let generation = sessionGeneration
        self.transport = transport
        self.breakpoints = breakpoints
        installedPaths = []
        breakpointIDs = [:]
        verifiedBreakpoints = [:]
        breakpointMessages = [:]
        state = .starting
        reason = "Starting debugger…"
        console = []
        threadID = nil
        threads = []
        invalidateStop()
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard !Task.isCancelled, let self, self.sessionGeneration == generation else { return }
                await self.receive(event)
            }
            guard let self, self.sessionGeneration == generation, self.state.isActive else { return }
            self.fail("Debugger connection closed.")
        }
        do {
            _ = try await transport.request("initialize", arguments: [
                "clientID": .string("AdaEditor"), "adapterID": .string("lldb"),
                "linesStartAt1": .bool(true), "columnsStartAt1": .bool(true),
                "pathFormat": .string("path"), "supportsVariableType": .bool(true),
                "supportsRunInTerminalRequest": .bool(false)
            ], timeout: .seconds(15))
            guard sessionGeneration == generation, state == .starting else { return }
            _ = try await transport.request("launch", arguments: arguments, timeout: .seconds(90))
            guard sessionGeneration == generation else { return }
            if state == .starting { state = .running; reason = "Running" }
        } catch {
            guard sessionGeneration == generation, state != .stopping, state != .terminated else { return }
            fail(error.localizedDescription)
            await transport.disconnect()
        }
    }

    public func stop() async {
        guard state.isActive || transport != nil || cleanupTask != nil else { return }
        state = .stopping
        sessionGeneration += 1
        eventTask?.cancel()
        configurationTask?.cancel()
        let current = transport
        transport = nil
        invalidateStop()
        await current?.disconnect()
        await cleanupTask?.value
        cleanupTask = nil
        state = .terminated
        reason = "Stopped"
    }

    public func setBreakpoints(_ breakpoints: [SourceBreakpoint]) async {
        self.breakpoints = breakpoints
        guard state == .running || state == .paused else { return }
        do { try await synchronizeBreakpoints() } catch { appendConsole(error.localizedDescription) }
    }

    public func control(_ command: String) async {
        guard let transport else { return }
        let mayRun = command == "pause" ? state == .running : state == .paused
        guard mayRun else { return }
        var arguments: [String: DebugJSON] = [:]
        if command == "pause", threadID == nil {
            do {
                let result = try await transport.request("threads", arguments: [:], timeout: .seconds(5))
                threadID = result["threads"].array.first?["id"].int
            } catch { appendConsole(error.localizedDescription); return }
        }
        if let threadID { arguments["threadId"] = .integer(threadID) }
        if command != "pause" { arguments["singleThread"] = .bool(false) }
        let generation = stopGeneration
        do {
            _ = try await transport.request(command, arguments: arguments, timeout: .seconds(10))
            if command != "pause", generation == stopGeneration {
                invalidateStop()
                state = .running
                reason = "Running"
            }
        } catch { appendConsole(error.localizedDescription) }
    }

    public func executeConsole(_ command: String) async {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendConsole("> \(command)")
        do { appendConsole(try await evaluate(command, context: "repl")) }
        catch { appendConsole(error.localizedDescription) }
    }

    public func evaluate(_ expression: String, context: String = "watch") async throws -> String {
        guard let transport, state == .paused || (context == "repl" && state == .running) else {
            throw DebuggerError.requestFailed("This command requires an active debugger; watches require a paused program.")
        }
        var arguments: [String: DebugJSON] = ["expression": .string(expression), "context": .string(context)]
        if let selectedFrameID { arguments["frameId"] = .integer(selectedFrameID) }
        let response = try await transport.request("evaluate", arguments: arguments, timeout: .seconds(15))
        return response["result"].string ?? ""
    }

    public func selectFrame(_ frame: DebugStackFrame) async {
        guard state == .paused, let transport else { return }
        selectedFrameID = frame.id
        variables = []
        onSelectFrame?(frame)
        let generation = stopGeneration
        do {
            let scopes = try await transport.request("scopes", arguments: ["frameId": .integer(frame.id)], timeout: .seconds(10))
            var result: [DebugVariable] = []
            for scope in scopes["scopes"].array where scope["expensive"].bool != true {
                guard let reference = scope["variablesReference"].int, reference > 0 else { continue }
                result += try await children(reference: reference)
            }
            guard generation == stopGeneration, selectedFrameID == frame.id else { return }
            variables = result
            await refreshWatches()
        } catch {
            guard generation == stopGeneration else { return }
            appendConsole(error.localizedDescription)
        }
    }

    public func selectThread(_ identifier: Int) async {
        guard state == .paused else { return }
        threadID = identifier
        invalidateStop()
        await refreshStack()
    }

    public func children(reference: Int) async throws -> [DebugVariable] {
        guard state == .paused, let transport else { throw DebuggerError.requestFailed("Program is not paused.") }
        let generation = stopGeneration
        let response = try await transport.request("variables", arguments: ["variablesReference": .integer(reference)], timeout: .seconds(10))
        guard generation == stopGeneration else { throw DebuggerError.requestFailed("Value belongs to an earlier stop.") }
        return response["variables"].array.map(DebugVariable.init)
    }

    public func refreshWatches() async {
        let generation = stopGeneration
        let frame = selectedFrameID
        var values: [String: String] = [:]
        for expression in watches {
            do { values[expression] = try await evaluate(expression) }
            catch { values[expression] = error.localizedDescription }
        }
        guard state == .paused, generation == stopGeneration, frame == selectedFrameID else { return }
        watchValues = values
    }

    public func appendConsole(_ text: String) {
        guard !text.isEmpty else { return }
        console.append(text)
        if console.count > 2000 { console.removeFirst(console.count - 2000) }
    }

    private func receive(_ event: DebugJSON) async {
        switch event["event"].string {
        case "initialized":
            configurationTask = Task { [weak self] in
                guard let self, let transport = self.transport else { return }
                do {
                    try await self.synchronizeBreakpoints()
                    _ = try await transport.request("configurationDone", arguments: [:], timeout: .seconds(10))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.fail(error.localizedDescription)
                    await transport.disconnect()
                }
            }
        case "stopped":
            invalidateStop()
            state = .paused
            reason = event["body"]["description"].string ?? event["body"]["reason"].string ?? "Paused"
            threadID = event["body"]["threadId"].int
            onStopped?()
            // Do not block consumption of continued/terminated events on inspection requests.
            Task { [weak self] in await self?.refreshStack() }
        case "continued":
            invalidateStop()
            state = .running
            reason = "Running"
        case "terminated", "exited":
            invalidateStop()
            state = .terminated
            reason = event["body"]["exitCode"].int.map { "Exited (\($0))" } ?? "Terminated"
            if let current = transport {
                transport = nil
                cleanupTask = Task { await current.disconnect() }
            }
        case "output": appendConsole(event["body"]["output"].string ?? "")
        case "breakpoint":
            let data = event["body"]["breakpoint"]
            if let identifier = data["id"].int, let id = breakpointIDs[identifier] {
                verifiedBreakpoints[id] = data["verified"].bool ?? false
                breakpointMessages[id] = data["message"].string
            }
        case "adapterError": fail(event["body"]["message"].string ?? "Debugger transport failed.")
        default: break
        }
    }

    private func synchronizeBreakpoints() async throws {
        guard let transport else { return }
        let groups = Dictionary(grouping: breakpoints.filter(\.enabled), by: \.path)
        for path in Set(groups.keys).union(installedPaths).sorted() {
            let requested = groups[path] ?? []
            let response = try await transport.request("setBreakpoints", arguments: [
                "source": .object(["path": .string(path)]),
                "breakpoints": .array(requested.map { .object(["line": .integer($0.line)]) })
            ], timeout: .seconds(10))
            for (breakpoint, result) in zip(requested, response["breakpoints"].array) {
                verifiedBreakpoints[breakpoint.id] = result["verified"].bool ?? false
                breakpointMessages[breakpoint.id] = result["message"].string
                if let identifier = result["id"].int { breakpointIDs[identifier] = breakpoint.id }
            }
        }
        installedPaths = Set(groups.keys)
    }

    private func refreshStack() async {
        guard state == .paused, let transport else { return }
        let generation = stopGeneration
        do {
            let response = try await transport.request("threads", arguments: [:], timeout: .seconds(10))
            guard generation == stopGeneration else { return }
            threads = response["threads"].array.compactMap { item in
                guard let id = item["id"].int else { return nil }
                return (id, item["name"].string ?? "Thread \(id)")
            }
            if threadID == nil { threadID = threads.first?.id }
            guard let threadID else { return }
            let stack = try await transport.request("stackTrace", arguments: ["threadId": .integer(threadID), "levels": .integer(100)], timeout: .seconds(10))
            guard generation == stopGeneration else { return }
            frames = stack["stackFrames"].array.map(DebugStackFrame.init)
            if let frame = frames.first { await selectFrame(frame) }
        } catch {
            guard generation == stopGeneration else { return }
            appendConsole(error.localizedDescription)
        }
    }

    private func invalidateStop() {
        stopGeneration += 1
        frames = []
        variables = []
        selectedFrameID = nil
        watchValues = [:]
    }

    private func fail(_ message: String) {
        invalidateStop()
        state = .failed
        reason = message
        appendConsole(message)
    }
}
