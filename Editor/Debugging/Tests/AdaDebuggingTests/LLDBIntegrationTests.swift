import Foundation
import Testing
@testable import AdaDebugging

#if os(macOS)
@Suite("Real Swift debugger", .serialized)
struct LLDBIntegrationTests {
    @Test @MainActor func stepIntoOutPauseStopAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ada-debugger-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("ControlFixture")
        try """
        import Foundation
        @inline(never) func leaf(_ input: Int) -> Int {
            let answer = input + 1
            return answer
        }
        @inline(never) func parent() {
            let result = leaf(4)
            print(result)
        }
        parent()
        while true { Thread.sleep(forTimeInterval: 0.02) }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-g", "-Onone", source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let locator = Process()
        let output = Pipe()
        locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        locator.arguments = ["--find", "lldb-dap"]
        locator.standardOutput = output
        try locator.run()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        locator.waitUntilExit()
        let session = DebugSession()
        do {
            for run in 0..<2 {
                let client = LLDBDebugClient()
                try await client.start(executable: URL(fileURLWithPath: path))
                await session.launch(transport: client, arguments: ["program": .string(executable.path)], breakpoints: [.init(path: source.path, line: 7)])
                try await waitUntil { session.state == .paused && session.frames.first?.line == 7 }
                if run == 0 {
                    await session.control("stepIn")
                    try await waitUntil { session.state == .paused && session.frames.first?.name.contains("leaf") == true }
                    await session.control("stepOut")
                    try await waitUntil { session.state == .paused && session.frames.first?.name.contains("parent") == true }
                    await session.setBreakpoints([])
                    await session.control("continue")
                    try await waitUntil { session.state == .running }
                    await session.control("pause")
                    try await waitUntil { session.state == .paused && !session.frames.isEmpty }
                }
                await session.stop()
                #expect(session.state == .terminated)
                #expect(session.frames.isEmpty)
            }
        } catch { await session.stop(); throw error }
    }

    @Test @MainActor func breakpointLocalsCommandsMemoryAndStep() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ada-debugger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("DebugFixture")
        try """
        func target(_ amount: Int) -> Int {
            let doubled = amount * 2
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
            bytes.initialize(repeating: 42, count: 4)
            print(doubled)
            bytes.deallocate()
            return doubled
        }
        print(target(21))
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-g", "-Onone", source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)
        let locator = Process()
        let output = Pipe()
        locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        locator.arguments = ["--find", "lldb-dap"]
        locator.standardOutput = output
        try locator.run()
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        locator.waitUntilExit()
        let client = LLDBDebugClient()
        try await client.start(executable: URL(fileURLWithPath: path))
        let session = DebugSession()
        session.watches = ["doubled"]
        await session.launch(transport: client, arguments: [
            "program": .string(executable.path), "cwd": .string(directory.path), "stopOnEntry": .bool(false)
        ], breakpoints: [SourceBreakpoint(path: source.path, line: 5)])
        do {
            try await waitUntil { session.state == .failed || (session.state == .paused && session.watchValues["doubled"] != nil) }
            #expect(session.state == .paused, "\(session.reason)\n\(session.console.joined(separator: "\n"))")
            _ = try #require(session.frames.first)
            #expect(session.frames.first?.line == 5)
            #expect(session.variables.contains { $0.name == "doubled" && $0.value.contains("42") })
            #expect(session.watchValues["doubled"]?.contains("42") == true)
            let command = try await session.evaluate("frame variable doubled", context: "repl")
            #expect(command.contains("42"))
            let pointer = try await session.evaluate("frame variable bytes", context: "repl")
            let address = try #require(pointer.firstMatch(of: /0x[0-9a-fA-F]+/)?.output)
            let memory = try await session.evaluate("memory read --format x --size 1 --count 4 \(address)", context: "repl")
            #expect(memory.components(separatedBy: "0x2a").count == 5)
            await session.control("next")
            try await waitUntil { session.state == .paused && session.frames.first?.line == 6 }
            await session.control("continue")
            try await waitUntil { session.state == .terminated }
            #expect(session.variables.isEmpty)
        } catch {
            await session.stop()
            throw error
        }
        await session.stop()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DebuggerError.timeout("integration assertion") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
