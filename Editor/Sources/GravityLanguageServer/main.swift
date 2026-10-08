import Foundation
import GravityLanguageServerProtocol

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
#endif

@main
struct GravityLanguageServerCommand {
    static func main() {
        do {
            let exitCode = try GravityLSPStdioServer().run()
            terminate(with: exitCode)
        } catch {
            let message = "gravity-lsp: \(error)\n"
            if let data = message.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
            terminate(with: 1)
        }
    }

    private static func terminate(with code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
            exit(code)
        #elseif canImport(WinSDK)
            ExitProcess(UInt32(bitPattern: code))
        #else
            #error("gravity-lsp does not support this platform")
        #endif
    }
}
