import Foundation

public final class GravityLSPStdioServer {
    private let input: FileHandle
    private let output: FileHandle
    private let session: GravityLanguageServerSession

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        session: GravityLanguageServerSession = GravityLanguageServerSession()
    ) {
        self.input = input
        self.output = output
        self.session = session
    }

    public func run() throws -> Int32 {
        var framer = GravityLSPMessageFramer()
        while let chunk = try input.read(upToCount: 4_096), !chunk.isEmpty {
            let payloads = try framer.append(chunk)
            for payload in payloads {
                let action: GravityLanguageServerAction
                do {
                    guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                        throw GravityLSPStdioError.invalidMessage
                    }
                    action = session.handle(message)
                } catch {
                    action = GravityLanguageServerAction(outgoingMessages: [
                        [
                            "error": ["code": -32700, "message": "Parse error"],
                            "id": NSNull(),
                            "jsonrpc": "2.0",
                        ]
                    ])
                }
                for message in action.outgoingMessages {
                    try output.write(contentsOf: GravityLSPMessageFramer.frame(message))
                }
                if let exitCode = action.exitCode {
                    return exitCode
                }
            }
        }
        return 0
    }
}

private enum GravityLSPStdioError: Error {
    case invalidMessage
}
