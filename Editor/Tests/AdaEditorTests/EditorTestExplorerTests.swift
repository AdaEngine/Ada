import Foundation
import Testing
@testable import AdaEditor

@Suite(.serialized)
struct EditorTestExplorerTests {
    @Test @MainActor
    func realSwiftPackageDiscoveryAndSingleRun() async throws {
        guard EditorDistribution.current.supportsSwiftProjects else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests/GameTests"), withIntermediateDirectories: true)
        try ProjectSystem.saveProject(ProjectSystem.defaultProject(projectName: "Game"), at: root)
        try """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "Game", targets: [.testTarget(name: "GameTests")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        import Testing
        @Suite struct One { @Test func same() { #expect(Bool(true)) } }
        @Suite struct Two { @Test func same() { #expect(Bool(false)) } }
        @Test func freeTest() { #expect(Bool(true)) }
        """.write(to: root.appendingPathComponent("Tests/GameTests/Tests.swift"), atomically: true, encoding: .utf8)
        let service = SwiftPMWorkspaceService()
        let explorer = EditorTestExplorer()
        explorer.refresh(projectURL: root, service: service)
        for _ in 0..<1500 where explorer.isDiscovering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(explorer.message == nil)
        #expect(explorer.items.count == 3)
        let selected = try #require(explorer.items.first { $0.id == "GameTests.One/same()" })
        explorer.begin(filter: nil, exactID: selected.id)
        let report = explorer.prepareSwiftReport()
        let result = await service.execute(.test(filter: selected.exactSwiftFilter, eventStreamPath: report.path), projectURL: root)
        #expect(result.succeeded)
        explorer.finish()
        #expect(explorer.items.first { $0.id == selected.id }?.status == .passed)
        #expect(explorer.items.filter { $0.status == .notRun }.count == 2)
    }

    @Test @MainActor
    func discoveryAndExactRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ada"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
        try """
        {"schemaVersion":3,"project":{"name":"Sample"},"build":{"system":"adascript","targets":[],"includedFiles":[],"excludedFiles":[]},
         "paths":{"sources":"Sources"},"runtime":{"entry":{"startupSystem":"Sample"},"moduleName":"Sample"}}
        """.write(to: root.appendingPathComponent(".ada/project.json"), atomically: true, encoding: .utf8)
        try """
        // @test func commented() {}
        @test("first jump")
        func jump() { expect(true); }
        @test
        func jumpAgain() { expect(false); }
        """.write(to: root.appendingPathComponent("Tests/Jump.ada"), atomically: true, encoding: .utf8)
        let settings = try ProjectSystem.loadProject(at: root)
        let runner = EditorAdaScriptTestRunner()
        let items = try runner.discover(project: settings, at: root)
        #expect(items.map(\.name) == ["first jump", "jumpAgain"])
        #expect(items.map(\.line) == [3, 5])
        let result = try runner.run(project: settings, at: root, filter: "jump", exactName: "jump")
        #expect(result.count == 1)
        #expect(result.first?.passed == true)
        let explorer = EditorTestExplorer()
        explorer.items = items
        explorer.begin(filter: "jump", exactID: items[0].id)
        explorer.receive(try #require(result.first))
        explorer.finish()
        #expect(explorer.items.map(\.status) == [.passed, .notRun])
    }

    @Test @MainActor
    func swiftDiscoveryAndPartialResults() throws {
        let explorer = EditorTestExplorer()
        explorer.items = EditorTestExplorer.swiftTests(from: "GameTests.FlightTests/jump()\nGameTests.FlightTests/jumpAgain()\n")
        #expect(explorer.items[0].filter == "GameTests.FlightTests/jump()")
        explorer.begin(filter: nil)
        explorer.consume("✔ Test jump() pas")
        #expect(explorer.items[0].status == .running)
        explorer.consume("sed after 0.001 seconds.\n✘ Test jumpAgain() failed after 0.002 seconds.\n")
        explorer.finish()
        #expect(explorer.items.map(\.status) == [.passed, .failed])
        explorer.begin(filter: nil, exactID: explorer.items[0].id)
        explorer.finish()
        #expect(explorer.items.map(\.status) == [.notRun, .failed])
    }

    @Test @MainActor
    func structuredResultsDisambiguateSuitesAndFreeFunctions() throws {
        let explorer = EditorTestExplorer()
        explorer.items = EditorTestExplorer.swiftTests(from: "GameTests.One/same()\nGameTests.Two/same()\nGameTests.freeTest()\n")
        #expect(explorer.items.count == 3)
        explorer.begin(filter: nil)
        explorer.consume("Test same() passed after 0.001 seconds.\n")
        #expect(explorer.items.allSatisfy { $0.status == .running })
        explorer.consumeEvents("""
        {"version":0,"kind":"event","payload":{"kind":"testEnded","testID":"GameTests.One/same()/File.swift:1:1","messages":[{"symbol":"pass","text":"passed"}]}}
        {"version":0,"kind":"event","payload":{"kind":"testEnded","testID":"GameTests.Two/same()/File.swift:2:1","messages":[{"symbol":"fail","text":"failed"}]}}
        {"version":0,"kind":"event","payload":{"kind":"testSkipped","testID":"GameTests.freeTest()/File.swift:3:1","messages":[]}}
        """)
        explorer.finish()
        #expect(explorer.items.map(\.status) == [.passed, .failed, .skipped])
    }

    @Test func parallelXCTestReportIncludesFailuresAndSkips() throws {
        let data = Data("""
        <testsuites><testsuite><testcase classname="GameTests.One" name="testPass"/>
        <testcase classname="GameTests.One" name="testFail"><failure message="Wrong value">expected 2</failure></testcase>
        <testcase classname="GameTests.Two" name="testSkip"><skipped/></testcase></testsuite></testsuites>
        """.utf8)
        let results = EditorXCTestReport.read(data)
        #expect(results.map(\.id) == ["GameTests.One/testPass", "GameTests.One/testFail", "GameTests.Two/testSkip"])
        #expect(results.map(\.failed) == [false, true, false])
        #expect(results[1].detail.contains("expected 2"))
        #expect(results[2].skipped)
    }
}
