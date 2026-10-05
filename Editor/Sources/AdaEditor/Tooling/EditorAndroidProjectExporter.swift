#if os(macOS)
  import Foundation

  actor EditorAndroidProjectExporter {
    private let runner: any EditorProcessRunning
    init(runner: any EditorProcessRunning = EditorProcessRunner()) { self.runner = runner }

    func export(
      project: AdaProject, at root: URL, to output: URL, sdk: EditorBuildSDK,
      configuration: EditorAndroidConfiguration, abi: String = "arm64-v8a", product: String? = nil,
      buildConfiguration: String = "debug", scratchDirectory: URL? = nil,
      log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void = { _ in }
    ) async throws -> URL {
      guard EditorDistribution.current.supportsSwiftProjects else {
        throw EditorPreviewBuildFailure(
          message: "Android export requires standalone macOS Ada Studio.")
      }
      var configuration = configuration
      configuration.environment["ADAENGINE_GRAVITY_PACKAGE_PATH"] = sdk.compilerRoot.path
      try configuration.validateBuildTools(engineRoot: sdk.engineRoot)
      let applicationID = EditorAndroidConfiguration.applicationID(
        for: project.project.name ?? root.lastPathComponent)
      let scratch = scratchDirectory ?? root.appendingPathComponent(".ada/android-build")
      if project.build.system.isAdaScript {
        #if canImport(GravityAOT)
          let options = EditorAdaScriptNativeExportOptions(
            destination: .android, gravityRoot: sdk.compilerRoot, engineRoot: sdk.engineRoot,
            swiftExecutable: configuration.swift,
            configuration: buildConfiguration == "release" ? .release : .debug,
            scratchDirectory: scratch,
            androidConfiguration: configuration, androidABI: abi,
            androidApplicationID: applicationID,
            androidSigningKey: root.appendingPathComponent(".ada/android-signing/debug.keystore"))
          return try await EditorAdaScriptNativeExporter(runner: runner).export(
            project: project, at: root, to: output, options: options, log: log)
        #else
          throw EditorPreviewBuildFailure(
            message: "This Studio build does not include AdaScript AOT export.")
        #endif
      }
      let root = root.resolvingSymlinksInPath()
      let output = output.standardizedFileURL
      guard output != root, !root.path.hasPrefix(output.path + "/"), !output.path.contains("/.ada/")
      else {
        throw EditorPreviewBuildFailure(
          message: "Android export output must be separate from project sources and build caches.")
      }
      let description = await runner.run(
        EditorProcessCommand(
          executablePath: configuration.swift,
          arguments: ["package", "describe", "--type", "json"],
          workingDirectory: root,
          environment: [
            "ADAENGINE_ANDROID": "0", "ADAENGINE_HEADLESS": "1", "ADAENGINE_DISABLE_SWAN": "1",
            "ADAENGINE_GRAVITY_PACKAGE_PATH": sdk.compilerRoot.path,
          ]), output: log)
      try Task.checkCancellation()
      guard description.succeeded,
        let model = SwiftPackageModel.parse(from: description.standardOutput),
        let product = product ?? project.run.executable ?? model.executableProducts.first?.name
      else {
        throw EditorPreviewBuildFailure(
          message: "Cannot inspect the Swift game package. \(description.standardError)")
      }
      let parent = output.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let stage = parent.appendingPathComponent(".ada-android-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: stage) }
      try copyProject(root, to: stage, excluding: output)
      try EditorAndroidSwiftPackage.prepare(
        at: stage, originalRoot: root, engineRoot: sdk.engineRoot, model: model, product: product,
        compilerRoot: sdk.compilerRoot)
      _ = try await Self.buildAPK(
        at: stage, product: product, applicationID: applicationID,
        label: project.project.displayName ?? product,
        engineRoot: sdk.engineRoot, configuration: configuration, abi: abi, scratch: scratch,
        buildConfiguration: buildConfiguration,
        signingKey: root.appendingPathComponent(".ada/android-signing/debug.keystore"),
        runner: runner, log: log)
      try Data(
        "{\"version\":1,\"applicationID\":\(String(reflecting: applicationID)),\"product\":\(String(reflecting: product))}"
          .utf8
      )
      .write(to: stage.appendingPathComponent("ada-android-export.json"))
      try Task.checkCancellation()
      try Self.publish(stage: stage, output: output)
      return output
    }

    static func buildAPK(
      at package: URL, product: String, applicationID: String, label: String, engineRoot: URL,
      configuration: EditorAndroidConfiguration, abi: String, scratch: URL,
      buildConfiguration: String = "debug", signingKey: URL? = nil,
      runner: any EditorProcessRunning,
      log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async throws -> URL {
      let output = package.appendingPathComponent("android")
      let signingArguments = signingKey.map { ["--debug-keystore", $0.path] } ?? []
      let command = EditorProcessCommand(
        executablePath: "/usr/bin/python3",
        arguments: [
          engineRoot.appendingPathComponent("Tools/Android/android.py").path,
          "build", "--package", package.path, "--product", product, "--application-id",
          applicationID, "--label", label,
          "--abi", abi, "--configuration", buildConfiguration, "--scratch", scratch.path,
          "--output", output.path,
        ] + signingArguments,
        workingDirectory: package, environment: configuration.environment)
      let result = await runner.run(command, output: log)
      try Task.checkCancellation()
      guard result.succeeded else {
        throw EditorPreviewBuildFailure(message: result.combinedOutput)
      }
      let apk = output.appendingPathComponent(product + "-" + buildConfiguration + ".apk")
      guard FileManager.default.fileExists(atPath: apk.path) else {
        throw EditorPreviewBuildFailure(message: "Android build did not produce an APK.")
      }
      return apk
    }

    static func apk(in output: URL) throws -> URL {
      let files = try FileManager.default.contentsOfDirectory(
        at: output.appendingPathComponent("android"), includingPropertiesForKeys: nil)
      let apks = files.filter {
        $0.pathExtension == "apk"
          && ($0.lastPathComponent.hasSuffix("-debug.apk")
            || $0.lastPathComponent.hasSuffix("-release.apk"))
      }
      guard apks.count == 1, let apk = apks.first else {
        throw EditorPreviewBuildFailure(message: "The export does not contain one signed game APK.")
      }
      return apk
    }

    private func copyProject(_ root: URL, to stage: URL, excluding output: URL) throws {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isDirectoryKey])
      else {
        throw EditorPreviewBuildFailure(message: "Cannot read the Swift project.")
      }
      for case let source as URL in enumerator {
        let name = source.lastPathComponent
        if name.hasPrefix(".build")
          || [".git", ".ada", ".swiftpm", ".codegraph", "Exports"].contains(name)
          || source.standardizedFileURL == output || source.standardizedFileURL == stage
        {
          enumerator.skipDescendants()
          continue
        }
        let relative = String(source.path.dropFirst(root.path.count + 1))
        let target = stage.appendingPathComponent(relative)
        if (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
          try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: source, to: target)
        }
      }
    }

    private static func publish(stage: URL, output: URL) throws {
      let backup = output.deletingLastPathComponent().appendingPathComponent(
        ".ada-android-backup-\(UUID().uuidString)")
      let existed = FileManager.default.fileExists(atPath: output.path)
      if existed {
        guard
          FileManager.default.fileExists(
            atPath: output.appendingPathComponent("ada-android-export.json").path)
        else {
          throw EditorPreviewBuildFailure(
            message: "Existing output is not an Android game export: \(output.path)")
        }
        try FileManager.default.moveItem(at: output, to: backup)
      }
      do { try FileManager.default.moveItem(at: stage, to: output) } catch {
        if existed { try? FileManager.default.moveItem(at: backup, to: output) }
        throw error
      }
      if existed { try? FileManager.default.removeItem(at: backup) }
    }
  }
#endif
