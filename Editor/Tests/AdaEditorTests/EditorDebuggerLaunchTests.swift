import AdaDebugging
import Foundation
import Testing

@testable import AdaEditor

#if os(macOS)
    @Suite("Editor debugger launch", .serialized)
    @MainActor
    struct EditorDebuggerLaunchTests {
        @Test func selectedSwiftPMProductBuildsAndStopsAtSavedBreakpoint() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaDebugLaunch-\(UUID().uuidString)")
            let source = root.appendingPathComponent("Sources/Probe/main.swift")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")])
            """
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try """
            func run(_ seed: Int) {
                let value = seed + 1
                print(value)
            }
            run(41)
            """
            .write(to: source, atomically: true, encoding: .utf8)
            try ProjectSystem.saveProject(AdaProject(schemaVersion: ProjectSystem.currentSchemaVersion), at: root)
            let viewModel = EditorViewModel(project: .init(name: "Probe", path: root.path))
            viewModel.debugger.configure(projectURL: root, storageURL: root.appendingPathComponent("debug-state.json"))
            viewModel.selectedRunProduct = "Probe"
            viewModel.selectedRunDestination = .macOS
            viewModel.debugger.toggleBreakpoint(path: source.path, line: 3)
            viewModel.debugger.watches = ["value"]
            viewModel.debugSelectedTarget()
            do {
                let deadline = ContinuousClock.now + .seconds(60)
                while viewModel.debugger.swift.watchValues["value"] == nil {
                    if !viewModel.debugger.isActive {
                        throw DebuggerError.requestFailed(
                            viewModel.debugger.status + " " + viewModel.debugger.swift.reason + "\n"
                                + viewModel.debugger.swift.console.joined(separator: "\n") + "\n"
                                + String(describing: viewModel.debugger.swift.verifiedBreakpoints) + "\n"
                                + String(describing: viewModel.debugger.swift.breakpointMessages)
                        )
                    }
                    guard ContinuousClock.now < deadline else {
                        throw DebuggerError.timeout("editor launch")
                    }
                    try await Task.sleep(for: .milliseconds(30))
                }
                #expect(viewModel.debugger.swift.state == .paused)
                #expect(viewModel.debugger.swift.watchValues["value"]?.contains("42") == true)
                #expect(viewModel.activeOutputTab == "Debug")
                #expect(viewModel.showBottomPanel)
                #expect(viewModel.workbench.activeDocument?.absolutePath == source.path)
                #expect(viewModel.isProjectRunning)
                await viewModel.debugger.swift.stop()
                #expect(!viewModel.isProjectRunning)
            } catch {
                viewModel.debugger.stop()
                await viewModel.debugger.swift.stop()
                throw error
            }
        }
    }
#endif
