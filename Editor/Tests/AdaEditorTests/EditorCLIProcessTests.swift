#if os(macOS)
import Foundation
import Testing

@testable import AdaEditor

@Suite("CLI process lifetime")
struct EditorCLIProcessTests {
    @Test func cancellationReapsProcessBeforeReadingExitStatus() async {
        let runner = EditorProcessRunner()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            await runner.run(EditorProcessCommand(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf 'ready\\n'; exec /bin/sleep 30"],
                workingDirectory: FileManager.default.temporaryDirectory
            )) { output in
                if output.text.contains("ready") { continuation.yield(()) }
            }
        }
        for await _ in events { break }
        continuation.finish()
        task.cancel()
        await runner.cancelAll()
        let result = await task.value
        #expect(!result.succeeded)
        #expect(result.standardOutput.contains("ready"))
    }
}
#endif
