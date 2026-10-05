#if os(macOS)
  @testable import AdaEditor
  import AdaEngine
  import Foundation
  import SwiftParser
  import Testing

  @Suite("Studio Android export")
  struct EditorAndroidExportTests {
    @Test func adbDestinationsKeepSerialAuthorizationAndKind() {
      let targets = EditorAndroidTools.parseDevices(
        """
        * daemon started successfully
        List of devices attached
        emulator-5556 device product:sdk model:Pixel_9 device:emu
        R58ABC unauthorized usb:1-3 model:Galaxy_S24
        phone2 offline
        """)
      #expect(targets.count == 3)
      #expect(targets[0].serial == "emulator-5556")
      #expect(targets[0].kind == .emulator)
      #expect(targets[1].kind == .device)
      #expect(!targets[1].isAvailable)
      #expect(!targets[2].isAvailable)
    }

    @Test func androidCLIOptionsAndMetadataRoundTrip() throws {
      let invocation = try EditorCLIInvocation(arguments: [
        "export", "--target", "android", "--device", "R58ABC", "--abi", "arm64-v8a",
      ])
      #expect(invocation.options["device"] == "R58ABC")
      #expect(throws: EditorCLIError.self) {
        try EditorCLIInvocation(arguments: [
          "export", "--target", "android", "--device", "R58ABC", "--emulator", "Pixel",
        ])
      }
      #expect(throws: EditorCLIError.self) {
        try EditorCLIInvocation(arguments: ["export", "--target", "macos", "--device", "R58ABC"])
      }
      let encoded = try JSONEncoder().encode(AdaProjectRun(destination: .android))
      #expect(try JSONDecoder().decode(AdaProjectRun.self, from: encoded).destination == .android)
      #expect(
        EditorAndroidConfiguration.applicationID(for: "Space Game")
          == EditorAndroidConfiguration.applicationID(for: "Space Game"))
      #expect(
        EditorAndroidConfiguration.applicationID(for: "Игра")
          != EditorAndroidConfiguration.applicationID(for: "Game"))
    }

    @Test(arguments: [false, true])
    func stagedSwiftAppPreservesSourcesAndPreparesResources(manualEntry: Bool) throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "Android Rewrite \(UUID().uuidString)")
      let stage = root.appendingPathComponent("Stage")
      let original = root.appendingPathComponent("Original")
      defer { try? FileManager.default.removeItem(at: root) }
      for directory in [stage, original] {
        try FileManager.default.createDirectory(
          at: directory.appendingPathComponent("Sources/Game"), withIntermediateDirectories: true)
      }
      let source = """
        import AdaEngine
        // A comment containing @main must not become an entry point.
        \(manualEntry ? "" : "@main ")private struct Game: App {
            var body: some AppScene {
                WindowGroup(content: { Text("Hello") }, assetBundle: .module)
            }
        }
        """ + (manualEntry ? """

        #if os(Android)
        @_cdecl("ada_android_start")
        public func startAndroidGame() { AndroidRuntime.start { Game() } }
        #endif

        """ : "")
      let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "SpaceGame", products: [.executable(name: "Game", targets: ["Game"])], dependencies: [
          .package(name: "AdaEngine", path: "../../Engine")
        ], targets: [.executableTarget(name: "Game", dependencies: [.product(name: "AdaEngine", package: "AdaEngine")], sources: ["Game.swift"], resources: [.copy("Assets")])])
        """
      for directory in [stage, original] {
        try manifest.write(
          to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(
          to: directory.appendingPathComponent("Sources/Game/Game.swift"), atomically: true,
          encoding: .utf8)
      }
      let model = SwiftPackageModel(
        name: "SpaceGame",
        products: [SwiftPackageProduct(name: "Game", type: "executable", targets: ["Game"])],
        targets: [
          SwiftPackageTarget(
            name: "Game", type: "executable", path: "Sources/Game", sources: ["Game.swift"],
            targetDependencies: [], productDependencies: ["AdaEngine"])
        ], dependencies: [])
      try EditorAndroidSwiftPackage.prepare(
        at: stage, originalRoot: original, engineRoot: root.appendingPathComponent("Engine"),
        model: model, product: "Game")
      #expect(
        try String(contentsOf: original.appendingPathComponent("Package.swift"), encoding: .utf8)
          == manifest)
      #expect(
        try String(
          contentsOf: original.appendingPathComponent("Sources/Game/Game.swift"), encoding: .utf8)
          == source)
      let game = try String(
        contentsOf: stage.appendingPathComponent("Sources/Game/Game.swift"), encoding: .utf8)
      #expect(!Parser.parse(source: game).hasError)
      #expect(game.contains("AndroidResourceBundle.bundle(named: \"SpaceGame_Game\")"))
      #expect(game.contains("AndroidRuntime.start { Game() }"))
      #expect(game.contains("Generated by Ada Studio") == !manualEntry)
      let package = try String(
        contentsOf: stage.appendingPathComponent("Package.swift"), encoding: .utf8)
      #expect(!Parser.parse(source: package).hasError)
      #expect(package.contains("type: .dynamic"))
      #expect(package.contains(".target(name:"))
      #expect(package.contains("sources: [\"Game.swift\"]"))
    }
  }

  @Suite("Studio Android real export", .serialized)
  struct EditorAndroidExportIntegrationTests {
    @Test(
      "Exports, signs and launches Swift and AdaScript through Studio services",
      .enabled(if: ProcessInfo.processInfo.environment["ADA_ANDROID_STUDIO_PROOF"] != nil))
    @MainActor
    func swiftAndAdaScriptOnAndroid() async throws {
      guard let proof = ProcessInfo.processInfo.environment["ADA_ANDROID_STUDIO_PROOF"] else {
        return
      }
      let root = URL(fileURLWithPath: proof)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let sdk = try EditorBuildSDK.locate()
      let configuration = EditorAndroidConfiguration.load(engineRoot: sdk.engineRoot)
      let runner = EditorProcessRunner()
      let tools = EditorAndroidTools(runner: runner)
      let targets = try await tools.discover(configuration: configuration, at: root)
      let target = try #require(
        targets.first {
          $0.serial == ProcessInfo.processInfo.environment["ADA_ANDROID_TEST_SERIAL"]
        })
      let serial = try await tools.resolve(
        target, configuration: configuration, at: root, log: { _ in })
      let abi = try await tools.abi(serial: serial, configuration: configuration, at: root)
      let scratch = ProcessInfo.processInfo.environment["ADA_ANDROID_TEST_SCRATCH"].map {
        URL(fileURLWithPath: $0)
      }
      for isScript in [false, true] {
        let projectRoot = root.appendingPathComponent(isScript ? "ScriptGame" : "SwiftGame")
        try FileManager.default.createDirectory(
          at: projectRoot.appendingPathComponent("Sources/Counter"),
          withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
          at: projectRoot.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        if !isScript {
          try
            "// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: \"Counter\", targets: [])\n"
            .write(
              to: projectRoot.appendingPathComponent("Package.swift"), atomically: true,
              encoding: .utf8)
        }
        var project = try ProjectSystem.createDefaultProject(
          at: projectRoot, buildSystem: isScript ? .adaScript : .swiftpm)
        project.runtime.entry.view = nil
        if isScript {
          project.runtime.entry.scene = "Assets/Main.ascn"
          try "func main() { return 42; }".write(
            to: projectRoot.appendingPathComponent("Sources/Main.ada"), atomically: true,
            encoding: .utf8)
          EditorComponentRegistry.registerBuiltIns()
          var scene = EditorSceneModel.default(projectName: "Android AOT")
          var sprite = EditorComponentRegistry.defaultPayload(
            for: EditorBuiltInComponentType.sprite)
          sprite["size"] = .object(["x": .double(160), "y": .double(160)])
          sprite["tintColor"] = .object([
            "red": .double(0.2), "green": .double(0.6), "blue": .double(1), "alpha": .double(1),
          ])
          scene.entities.append(
            EditorSceneEntity(
              id: "box", name: "Android box", enabled: true, parent: nil,
              components: [
                EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(
                  for: EditorBuiltInComponentType.transform),
                EditorBuiltInComponentType.sprite: sprite,
                EditorBuiltInComponentType.visibility: EditorComponentRegistry.defaultPayload(
                  for: EditorBuiltInComponentType.visibility),
              ]))
          try scene.encodedYAML().write(
            to: projectRoot.appendingPathComponent("Assets/Main.ascn"), atomically: true,
            encoding: .utf8)
        } else {
          try """
          // swift-tools-version: 6.2
          import PackageDescription
          let package = Package(name: "Counter", products: [.executable(name: "Counter", targets: ["Counter"])], dependencies: [
              .package(name: "AdaEngine", path: \(String(reflecting: sdk.engineRoot.path)))
          ], targets: [.executableTarget(name: "Counter", dependencies: [.product(name: "AdaEngine", package: "AdaEngine")], resources: [.copy("Assets")])])
          """.write(
            to: projectRoot.appendingPathComponent("Package.swift"), atomically: true,
            encoding: .utf8)
          try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("Sources/Counter/Assets"),
            withIntermediateDirectories: true)
          try Data("bundled asset".utf8).write(
            to: projectRoot.appendingPathComponent("Sources/Counter/Assets/fixture.txt"))
          try """
          import AdaEngine
          @main struct Counter: App {
              var body: some AppScene { WindowGroup(content: { CounterView() }, assetBundle: .module) }
          }
          struct CounterView: View {
              @State private var taps = 0
              var body: some View {
                  VStack(spacing: 20) {
                      Text("Exported by Ada Studio").foregroundColor(.white)
                      Text("Taps: \\(taps)").foregroundColor(.white)
                      Button("Tap +1") { taps += 1; AndroidRuntime.log("StudioCounter taps=\\(taps)") }
                  }
              }
          }
          """.write(
            to: projectRoot.appendingPathComponent("Sources/Counter/Counter.swift"),
            atomically: true, encoding: .utf8)
        }
        try ProjectSystem.saveProject(project, at: projectRoot)
        let output = projectRoot.appendingPathComponent("Exports/Android")
        let fixtureID = EditorAndroidConfiguration.applicationID(
          for: project.project.name ?? projectRoot.lastPathComponent)
        _ = await runner.run(
          EditorProcessCommand(
            executablePath: configuration.adb, arguments: ["-s", serial, "uninstall", fixtureID],
            workingDirectory: projectRoot))
        let exporter = EditorAndroidProjectExporter(runner: runner)
        let result = try await exporter.export(
          project: project, at: projectRoot, to: output, sdk: sdk, configuration: configuration,
          abi: abi,
          product: isScript ? nil : "Counter", scratchDirectory: scratch,
          log: { event in print(event.text, terminator: "") })
        let apk = try EditorAndroidProjectExporter.apk(in: result)
        #expect((try apk.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 1_000_000)
        let applicationID = EditorAndroidConfiguration.applicationID(
          for: project.project.name ?? projectRoot.lastPathComponent)
        try await tools.launch(
          apk: apk, applicationID: applicationID, serial: serial, configuration: configuration,
          at: projectRoot, requiresAOTReady: isScript)
        try await Task.sleep(for: .seconds(3))
        let pid = await runner.run(
          EditorProcessCommand(
            executablePath: configuration.adb,
            arguments: ["-s", serial, "shell", "pidof", applicationID],
            workingDirectory: projectRoot))
        #expect(pid.succeeded)
        let processID = pid.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let logs = await runner.run(
          EditorProcessCommand(
            executablePath: configuration.adb,
            arguments: ["-s", serial, "logcat", "-d", "--pid=" + processID, "-s", "AdaEngine:V"],
            workingDirectory: projectRoot))
        #expect(logs.standardOutput.contains("Android frame loop started"))
        #expect(!logs.standardOutput.contains("WebGPU error"))
        if isScript { #expect(logs.standardOutput.contains("Native game ready")) }
      }
    }
  }
#endif
