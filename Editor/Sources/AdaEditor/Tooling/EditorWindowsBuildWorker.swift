#if os(Windows)
import Foundation

/// Cross compilation uses Linux tools through WSL. Arguments are passed directly
/// to exec; project paths and configuration never become shell source.
enum EditorWindowsBuildWorker {
    static func linuxPath(_ path: String) -> String {
        let value = path.replacingOccurrences(of: "\\", with: "/")
        let bytes = Array(value.utf8)
        if bytes.count >= 3, bytes[1] == 58, bytes[2] == 47 {
            return "/mnt/" + String(value.prefix(1)).lowercased() + String(value.dropFirst(2))
        }
        return value
    }

    static func webCommand(
        package: URL, output: URL, product: String, engineRoot: URL, gravityRoot: URL?,
        swift: String, sdk: String, configuration: String, serve: Bool, scratch: URL? = nil,
        environment: [String: String] = [:]
    ) -> EditorProcessCommand {
        var arguments = ["--mode", "web", "--package", linuxPath(package.path), "--output", linuxPath(output.path),
                         "--product", product, "--swift-sdk", sdk, "--configuration", configuration]
        if !swift.isEmpty { arguments += ["--swift", linuxPath(swift)] }
        if let scratch { arguments += ["--scratch", linuxPath(scratch.path)] }
        if serve { arguments.append("--serve") }
        if let gravityRoot { arguments += ["--gravity", linuxPath(gravityRoot.path)] }
        if let saga = environment["ADAENGINE_SAGA_PACKAGE_PATH"] ?? ProcessInfo.processInfo.environment["ADAENGINE_SAGA_PACKAGE_PATH"],
           !saga.isEmpty {
            arguments += ["--saga", linuxPath(saga)]
        }
        return command(arguments, package: package, engineRoot: engineRoot)
    }

    static func androidCommand(
        package: URL, product: String, applicationID: String, label: String, engineRoot: URL,
        configuration: EditorAndroidConfiguration, abi: String, scratch: URL,
        buildConfiguration: String, signingKey: URL?
    ) -> EditorProcessCommand {
        var arguments = ["--mode", "android", "--package", linuxPath(package.path), "--output", linuxPath(package.appendingPathComponent("android").path),
                         "--product", product, "--application-id", applicationID, "--label", label,
                         "--abi", abi, "--scratch", linuxPath(scratch.path), "--configuration", buildConfiguration,
                         "--swift-sdk", configuration.environment["SWIFT_ANDROID_SDK"] ?? "swift-6.4.0-RELEASE_android"]
        if let signingKey { arguments += ["--debug-keystore", linuxPath(signingKey.path)] }
        if let gravity = ProcessInfo.processInfo.environment["ADAENGINE_GRAVITY_PACKAGE_PATH"] {
            arguments += ["--gravity", linuxPath(gravity)]
        }
        if configuration.environment["ADAENGINE_SAGA_NATIVE"] == "1" {
            let saga = configuration.environment["ADAENGINE_SAGA_PACKAGE_PATH"]
                ?? engineRoot.deletingLastPathComponent().appendingPathComponent("SAGA").path
            arguments += ["--saga", linuxPath(saga)]
        } else if let swan = configuration.environment["ADAENGINE_SWAN_PACKAGE_PATH"] {
            arguments += ["--swan", linuxPath(swan)]
        }
        return command(arguments, package: package, engineRoot: engineRoot)
    }

    private static func command(_ arguments: [String], package: URL, engineRoot: URL) -> EditorProcessCommand {
        EditorProcessCommand(
            executablePath: EditorHostTools.executable("wsl", windowsName: "wsl.exe"),
            arguments: ["--cd", linuxPath(package.path), "--exec", "python3",
                        linuxPath(engineRoot.appendingPathComponent("Tools/Windows/build_worker.py").path),
                        "--engine", linuxPath(engineRoot.path)] + arguments,
            workingDirectory: package, environment: [:])
    }
}
#endif
