#if DEBUG && os(iOS) && targetEnvironment(simulator)
    import Foundation
    import UIKit

    /// Opt-in Simulator workload using the same operation/background path as the agent.
    @MainActor
    enum MobileEditorBackgroundAgentQA {
        static func start() {
            let operation = MobileEditorAgentOperation(projectID: UUID())
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("background-agent-qa.txt")
            operation.start(
                projectName: "Background QA",
                requestBackground: { id, coordinator in
                    if #available(iOS 26.0, *) {
                        EditorContinuedProcessing.shared.request(
                            for: id,
                            coordinator: coordinator,
                            onUnavailable: operation.backgroundUnavailable
                        )
                    }
                },
                work: {
                    try Data().write(to: output, options: .atomic)
                    let handle = try FileHandle(forWritingTo: output)
                    defer { try? handle.close() }
                    for index in 1 ... 45 {
                        try Task.checkCancellation()
                        let record = "\(index) state=\(UIApplication.shared.applicationState.rawValue) \(Date())\n"
                        try handle.write(contentsOf: Data(record.utf8))
                        try handle.synchronize()
                        print("BACKGROUND_AGENT_QA \(record)")
                        operation.update("Verified record \(index) of 45")
                        operation.completedStep()
                        if index == 12, CommandLine.arguments.contains("--mobile-background-agent-qa-failure") {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    return .init(succeeded: true, detail: "45 records verified")
                },
                finished: { state, detail in
                    print("BACKGROUND_AGENT_QA finished=\(state.rawValue) \(detail) file=\(output.path)")
                }
            )
        }
    }
#endif
