import AdaEditor
import AdaEngine
import AdaMCPCore
import AdaMCPPlugin
import Darwin
import Dispatch
import Foundation
import MCP

@main
enum StudioInteractionHost {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("adastudio-flow <flow.yaml> | --stdio")
            return
        }
        guard arguments.count == 1, let argument = arguments.first else {
            throw FlowError("Usage: adastudio-flow <flow.yaml> | --stdio")
        }
        let source: String?
        if argument == "--stdio" {
            source = nil
        } else {
            let flowURL = URL(fileURLWithPath: argument)
            guard let size = try flowURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536 else {
                throw FlowError("Flow exceeds 64 KiB.")
            }
            source = try String(contentsOf: flowURL, encoding: .utf8)
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ada-studio-flow-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard setenv("CFFIXED_USER_HOME", temporary.path, 1) == 0,
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == temporary.standardizedFileURL.path else {
            throw FlowError("Could not isolate the host's settings and caches.")
        }
        let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        shutdown.setEventHandler {
            try? FileManager.default.removeItem(at: temporary)
            Foundation.exit(source == nil ? 0 : 130)
        }
        shutdown.resume()
        defer { shutdown.cancel() }
        let inputMonitor = source == nil ? Task { await Self.exitWhenMCPInputCloses(project: temporary) } : nil
        defer { inputMonitor?.cancel() }
        let projectDirectory = temporary.appendingPathComponent("Project", isDirectory: true)
        let assets = projectDirectory.appendingPathComponent("Assets/Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        guard let fixture = Bundle.module.url(forResource: "Main", withExtension: "ascn", subdirectory: "Fixtures") else {
            throw FlowError("Missing scene fixture.")
        }
        try FileManager.default.copyItem(at: fixture, to: assets.appendingPathComponent("Main.ascn"))
        try ProjectSystem.createDefaultProject(at: projectDirectory, buildSystem: .adaScript)
        let project = EditorProjectReference(name: "Studio Flow Fixture", path: projectDirectory.path)
        let runner = StudioInteractionRunner(workbench: EditorWorkbenchInspection(project: project))
        try await AppRuntime.run(StudioInteractionApp(runner: runner, source: source, project: temporary))
    }

    private static func exitWhenMCPInputCloses(project: URL) async {
        // Observe pipe closure without consuming the bytes owned by AdaMCP's transport.
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLHUP), revents: 0)
        let closed = Int16(POLLHUP | POLLERR | POLLNVAL)
        while !Task.isCancelled {
            if poll(&descriptor, 1, 0) > 0, descriptor.revents & closed != 0 {
                try? FileManager.default.removeItem(at: project)
                Foundation.exit(0)
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
    }
}

private struct StudioInteractionApp: App {
    let runner: StudioInteractionRunner
    let source: String?
    let project: URL

    var body: some AppScene {
        WindowGroup {
            runner.workbench.content
                .onAppear { runner.workbenchMounted = true }
                .task {
                    guard let source else {
                        return
                    }
                    let report = await runner.run(source: source)
                    if let output = try? encode(report) { print(output) }
                    try? FileManager.default.removeItem(at: project)
                    Foundation.exit(report.status == "passed" ? 0 : 1)
                }
        }
        .windowMode(.windowed)
        .singleWindow(true)
        .windowTitle("Ada Studio Interaction Host")
        .minimumSize(width: 1160, height: 760)
        .transformAppWorlds { runner.worlds = $0 }
        .addPlugins(MCPPlugin(configuration: .init(
            enableHTTP: false,
            enableStdio: source == nil,
            serverName: "Ada Studio Interaction Host",
            instructions: "Run a version 1 studio-ui YAML flow with editor.ui.run_flow. This host uses a disposable fixture scene.",
            additionalTools: {
                [
                    Tool(
                        name: "editor.ui.run_flow",
                        description: "Run version 1 studio-ui YAML using tapOn, drag, pressKey and assertScene.",
                        inputSchema: [
                            "type": "object",
                            "required": ["source"],
                            "properties": ["source": ["type": "string", "description": "Contents of the same YAML accepted by adastudio-flow."]]
                        ]
                    )
                ]
            },
            additionalToolHandler: { name, arguments in
                guard name == "editor.ui.run_flow" else {
                    return nil
                }
                guard let source = arguments["source"]?.stringValue else {
                    return result("A source string is required.", failed: true)
                }
                let report = await runner.run(source: source)
                let payload = try? encode(report)
                return result(payload ?? "Could not encode the flow report.", failed: report.status != "passed" || payload == nil)
            },
            traceRecorder: nil,
            enableDiscovery: false
        )))
    }
}

private func encode(_ report: StudioInteractionRunner.Report) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let text = String(bytes: try encoder.encode(report), encoding: .utf8) else {
        throw FlowError("Could not encode the flow report as UTF-8.")
    }
    return text
}

private func result(_ text: String, failed: Bool) -> CallTool.Result {
    CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: failed)
}
