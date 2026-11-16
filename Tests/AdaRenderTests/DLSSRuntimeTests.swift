import AdaRender
import Testing

@Suite("DLSS runtime discovery")
struct DLSSRuntimeTests {
    private let library = DLSSRuntime.libraryName
    private let bridge = DLSSRuntime.bridgeName

    @Test func missingRuntimeReportsWhereItLooked() {
        let status = DLSSRuntime.probe(environment: [:], executableDirectory: "/game/bin", fileExists: { _ in false })
        #expect(!status.isAvailable)
        let reason = status.unavailableReason ?? ""
        #expect(reason.contains("not found") && reason.contains(DLSSRuntime.environmentKey))
    }

    @Test func bridgeAndLibraryTogetherAreFound() {
        let present: Set<String> = ["/game/bin/\(library)", "/game/bin/\(bridge)"]
        let status = DLSSRuntime.probe(environment: [:], executableDirectory: "/game/bin") { present.contains($0) }
        #expect(status.isAvailable)
        #expect(DLSSRuntime.locate(environment: [:], executableDirectory: "/game/bin") { present.contains($0) } == "/game/bin")
    }

    @Test func libraryWithoutTheBridgeIsReportedAsMissingTheBridge() {
        let status = DLSSRuntime.probe(environment: [:], executableDirectory: "/game/bin") { $0 == "/game/bin/\(library)" }
        #expect(!status.isAvailable)
        #expect((status.unavailableReason ?? "").contains(bridge))
    }

    @Test func configuredDirectoryIsPreferredOverTheExecutableDirectory() {
        let present: Set<String> = [
            "/sdk/lib/\(library)", "/sdk/lib/\(bridge)", "/game/bin/\(library)", "/game/bin/\(bridge)",
        ]
        let located = DLSSRuntime.locate(environment: [DLSSRuntime.environmentKey: "/sdk/lib"], executableDirectory: "/game/bin") {
            present.contains($0)
        }
        #expect(located == "/sdk/lib")
    }

    @Test func partsInDifferentDirectoriesDoNotCount() {
        let present: Set<String> = ["/sdk/lib/\(library)", "/game/bin/\(bridge)"]
        let status = DLSSRuntime.probe(environment: [DLSSRuntime.environmentKey: "/sdk/lib"], executableDirectory: "/game/bin") {
            present.contains($0)
        }
        #expect(!status.isAvailable)
    }

    @Test func relativeAndEmptyDirectoriesAreNeverSearched() {
        var checked: [String] = []
        let status = DLSSRuntime.probe(environment: [DLSSRuntime.environmentKey: "relative/dir"], executableDirectory: "") { path in
            checked.append(path)
            return true
        }
        #expect(checked.isEmpty)
        #expect((status.unavailableReason ?? "").contains("not found"))
    }
}
