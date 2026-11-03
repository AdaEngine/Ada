#if os(Windows)
import Foundation
import Testing
@testable import AdaEditor

@Suite("Windows ACP pipe backpressure", .serialized)
struct EditorWindowsACPTransportTests {
    @Test("A short interactive reply is delivered before the producer writes again", .timeLimit(.minutes(1)))
    func shortInteractiveReply() async throws {
        let process = try makeProcess("import os; os.write(1,b'x'); assert os.read(0,1)==b'y'", closeInput: false)
        defer { process.terminate() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            process.terminate()
        }
        defer { deadline.cancel() }
        var iterator = EditorWindowsACPTransport.chunks(process.output).makeAsyncIterator()
        #expect(try await iterator.next() == Data("x".utf8))
        try process.input.write(contentsOf: Data("y".utf8))
        try process.input.close()
        #expect(try await iterator.next() == nil)
        for await code in process.exit { #expect(code == 0) }
    }

    @Test("Slow consumers receive every byte of simultaneous stdout and stderr bursts", .timeLimit(.minutes(1)))
    func outputBurst() async throws {
        let process = try makeProcess(#"""
        import os, threading
        def write(fd, value):
            block = bytes([value]) * 4096
            for _ in range(8192):
                offset = 0
                while offset < len(block):
                    offset += os.write(fd, block[offset:])
        other = threading.Thread(target=write, args=(2, 90))
        other.start()
        write(1, 165)
        other.join()
        """#)
        defer { process.terminate() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            process.terminate()
        }
        defer { deadline.cancel() }
        let output = EditorWindowsACPTransport.chunks(process.output)
        let errors = EditorWindowsACPTransport.chunks(process.error)
        // Let a push-based reader fill its old 256-entry queue before consuming.
        // A pull-based reader leaves the bytes safely in the kernel pipe instead.
        try await Task.sleep(for: .milliseconds(250))
        async let out = collect(output, byte: 165)
        async let err = collect(errors, byte: 90)
        let (stdout, stderr) = try await (out, err)
        var exitCode: Int32 = -1
        for await code in process.exit { exitCode = code }
        #expect(exitCode == 0)
        #expect(stdout == 32 * 1024 * 1024)
        #expect(stderr == 32 * 1024 * 1024)
    }

    @Test("Terminating an idle producer releases a pending read", .timeLimit(.minutes(1)))
    func terminationWhileReading() async throws {
        let process = try makeProcess("import time; time.sleep(60)")
        defer { process.terminate() }
        let output = EditorWindowsACPTransport.chunks(process.output)
        let reader = Task {
            var iterator = output.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        process.terminate()
        do {
            #expect(try await reader.value == nil)
        } catch is CancellationError {
            // Both cancellation before the read and EOF after termination are valid.
        }
        for await code in process.exit { #expect(code != 0) }
    }

    private func collect(_ chunks: AsyncThrowingStream<Data, any Error>, byte: UInt8) async throws -> Int {
        var count = 0
        var reads = 0
        for try await chunk in chunks {
            #expect(chunk.count <= EditorWindowsACPTransport.maximumChunkBytes)
            #expect(chunk == Data(repeating: byte, count: chunk.count))
            count += chunk.count
            reads += 1
            if reads.isMultiple(of: 32) { try await Task.sleep(for: .milliseconds(2)) }
        }
        return count
    }

    private func makeProcess(_ source: String, closeInput: Bool = true) throws -> EditorWindowsProcess {
        let process = try EditorWindowsProcess(
            executable: URL(fileURLWithPath: EditorHostTools.executable("python3", windowsName: "python.exe")),
            arguments: ["-u", "-c", source], directory: nil,
            environment: EditorWindowsAgentCommand.environment([:])
        )
        if closeInput { try process.input.close() }
        return process
    }
}
#endif
