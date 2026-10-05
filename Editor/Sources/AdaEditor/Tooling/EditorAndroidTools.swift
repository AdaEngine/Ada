import Foundation

struct EditorAndroidTarget: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case device, emulator }
  let id: String
  let name: String
  let kind: Kind
  let serial: String?
  let avd: String?
  let state: String
  var isAvailable: Bool { state == "device" || avd != nil }
  var title: String { name + (serial == nil ? " · Start emulator" : " · " + state) }
}

struct EditorAndroidConfiguration: Equatable, Sendable {
  static let preferenceKey = "AdaStudio.Android.Tools"
  static let fields: [(String, String)] = [
    ("ANDROID_HOME", "Android SDK"), ("ANDROID_NDK_HOME", "Android NDK"),
    ("SWIFT_ANDROID_SWIFT", "Swift 6.4 executable"),
    ("SWIFT_ANDROID_SDKS_PATH", "Swift Android SDKs"),
    ("SWIFT_ANDROID_SDK", "Swift Android SDK identifier"),
    ("ADAENGINE_SWAN_PACKAGE_PATH", "Swan package"),
    ("SWAN_LOCAL_DAWN", "Dawn artifact (relative to Swan)"),
  ]
  var environment: [String: String]

  static func load(
    engineRoot: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
    preferences: [String: String]? = UserDefaults.standard.dictionary(forKey: preferenceKey)
      as? [String: String]
  ) -> Self {
    var values: [String: String] = [:]
    // Development-only defaults are data, never sourced or executed as shell code.
    if let engineRoot,
      let data = try? String(
        contentsOf: engineRoot.appendingPathComponent(".build-android/local-env.sh"),
        encoding: .utf8)
    {
      for line in data.split(separator: "\n") where line.hasPrefix("export ") {
        let pair = line.dropFirst(7).split(separator: "=", maxSplits: 1).map(String.init)
        if pair.count == 2,
          fields.contains(where: { $0.0 == pair[0] }) || pair[0] == "ANDROID_AVD_HOME"
        {
          values[pair[0]] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
      }
    }
    for (key, value) in environment
    where fields.contains(where: { $0.0 == key }) || key == "ANDROID_AVD_HOME" {
      if !value.isEmpty { values[key] = value }
    }
    for (key, value) in preferences ?? [:] where !value.isEmpty { values[key] = value }
    let home = FileManager.default.homeDirectoryForCurrentUser
    values["ANDROID_HOME"] =
      values["ANDROID_HOME"] ?? home.appendingPathComponent("Library/Android/sdk").path
    values["SWIFT_ANDROID_SDK"] = values["SWIFT_ANDROID_SDK"] ?? "swift-6.4.0-RELEASE_android"
    values["SWIFT_ANDROID_SDKS_PATH"] =
      values["SWIFT_ANDROID_SDKS_PATH"]
      ?? home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks").path
    values["SWIFT_ANDROID_SWIFT"] =
      values["SWIFT_ANDROID_SWIFT"]
      ?? home.appendingPathComponent(
        "Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/bin/swift"
      ).path
    if let engineRoot {
      let swan = engineRoot.deletingLastPathComponent().appendingPathComponent("Swan")
      let development = engineRoot.deletingLastPathComponent().appendingPathComponent("swan")
      values["ADAENGINE_SWAN_PACKAGE_PATH"] =
        values["ADAENGINE_SWAN_PACKAGE_PATH"]
        ?? (FileManager.default.fileExists(
          atPath: swan.appendingPathComponent("Package.swift").path) ? swan.path : development.path)
    }
    values["SWAN_LOCAL_DAWN"] = values["SWAN_LOCAL_DAWN"] ?? "Dawn/dist/android.artifactbundle"
    if values["ANDROID_NDK_HOME"] == nil, let sdk = values["ANDROID_HOME"] {
      let ndks =
        (try? FileManager.default.contentsOfDirectory(
          at: URL(fileURLWithPath: sdk).appendingPathComponent("ndk"),
          includingPropertiesForKeys: nil)) ?? []
      values["ANDROID_NDK_HOME"] =
        ndks.sorted {
          $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }.last?.path
    }
    values["ADAENGINE_ANDROID"] = "1"
    values["SWAN_RUNTIME_ONLY"] = "1"
    values["ADAENGINE_HEADLESS"] = "0"
    values["ADAENGINE_DISABLE_SWAN"] = "0"
    return Self(environment: values)
  }

  var adb: String {
    URL(fileURLWithPath: environment["ANDROID_HOME"] ?? "").appendingPathComponent(
      "platform-tools/adb"
    ).path
  }
  var emulator: String {
    URL(fileURLWithPath: environment["ANDROID_HOME"] ?? "").appendingPathComponent(
      "emulator/emulator"
    ).path
  }
  var swift: String { environment["SWIFT_ANDROID_SWIFT"] ?? "swift" }

  func validateBuildTools(engineRoot: URL) throws {
    for key in [
      "SWIFT_ANDROID_SWIFT", "SWIFT_ANDROID_SDKS_PATH", "ANDROID_HOME", "ANDROID_NDK_HOME",
      "ADAENGINE_SWAN_PACKAGE_PATH",
    ] {
      guard let path = environment[key], FileManager.default.fileExists(atPath: path) else {
        throw EditorPreviewBuildFailure(
          message: "Configure \(key) in Settings → Android. The path is missing or unavailable.")
      }
    }
    guard
      FileManager.default.fileExists(
        atPath: engineRoot.appendingPathComponent("Tools/Android/android.py").path)
    else {
      throw EditorPreviewBuildFailure(
        message: "This Studio build SDK does not include Android export tools.")
    }
  }

  static func applicationID(for name: String) -> String {
    let slug = name.lowercased().replacingOccurrences(
      of: "[^a-z0-9_]", with: "_", options: .regularExpression)
    var hash: UInt32 = 2_166_136_261
    for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    return "org.adaengine.games.g_" + String(slug.prefix(48)) + "_" + String(hash, radix: 16)
  }
}

#if os(macOS)
  actor EditorAndroidTools {
    private let runner: any EditorProcessRunning
    private var emulators: [String: Process] = [:]
    init(runner: any EditorProcessRunning = EditorProcessRunner()) { self.runner = runner }

    static func parseDevices(_ text: String) -> [EditorAndroidTarget] {
      text.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*"),
          ["device", "offline", "unauthorized", "no"].contains(fields[1])
        else { return nil }
        let serial = fields[0]
        let model =
          fields.first(where: { $0.hasPrefix("model:") }).map {
            String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
          } ?? serial
        return EditorAndroidTarget(
          id: "device:" + serial, name: model + " (" + serial + ")",
          kind: serial.hasPrefix("emulator-") ? .emulator : .device,
          serial: serial, avd: nil, state: fields[1])
      }
    }

    func discover(configuration: EditorAndroidConfiguration, at root: URL) async throws
      -> [EditorAndroidTarget]
    {
      let devices = try await execute(
        configuration.adb, ["devices", "-l"], configuration: configuration, at: root)
      var targets = Self.parseDevices(devices.standardOutput)
      guard FileManager.default.isExecutableFile(atPath: configuration.emulator) else {
        return targets
      }
      let avds = try await execute(
        configuration.emulator, ["-list-avds"], configuration: configuration, at: root)
      var runningNames: Set<String> = []
      for target in targets where target.kind == .emulator && target.state == "device" {
        if let serial = target.serial,
          let result = try? await execute(
            configuration.adb, ["-s", serial, "emu", "avd", "name"], configuration: configuration,
            at: root),
          let name = result.standardOutput.split(whereSeparator: \.isNewline).first
        {
          runningNames.insert(String(name))
        }
      }
      for name in avds.standardOutput.split(whereSeparator: \.isNewline).map(String.init)
      where !name.isEmpty && !runningNames.contains(name) {
        targets.append(
          EditorAndroidTarget(
            id: "avd:" + name, name: name, kind: .emulator, serial: nil, avd: name, state: "stopped"
          ))
      }
      targets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      return targets
    }

    func resolve(
      _ target: EditorAndroidTarget, configuration: EditorAndroidConfiguration, at root: URL,
      log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void
    ) async throws -> String {
      if let serial = target.serial {
        guard target.state == "device" else {
          throw EditorPreviewBuildFailure(
            message:
              "Android device \(serial) is \(target.state). Authorize USB debugging and reconnect it."
          )
        }
        _ = try await execute(
          configuration.adb, ["-s", serial, "get-state"], configuration: configuration, at: root)
        return serial
      }
      guard let name = target.avd else {
        throw EditorPreviewBuildFailure(message: "Select an Android device or emulator.")
      }
      let devices = try await discover(configuration: configuration, at: root)
      for device in devices where device.kind == .emulator && device.state == "device" {
        if let serial = device.serial,
          let result = try? await execute(
            configuration.adb, ["-s", serial, "emu", "avd", "name"], configuration: configuration,
            at: root),
          result.standardOutput.split(whereSeparator: \.isNewline).first.map(String.init) == name
        {
          return serial
        }
      }
      let usedPorts = Set(
        devices.compactMap { $0.serial?.replacingOccurrences(of: "emulator-", with: "") }
          .compactMap(Int.init))
      guard
        let port = stride(from: 5554, through: 5680, by: 2).first(where: { !usedPorts.contains($0) }
        )
      else {
        throw EditorPreviewBuildFailure(message: "No Android emulator port is available.")
      }
      let serial = "emulator-\(port)"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: configuration.emulator)
      process.arguments = ["-avd", name, "-port", String(port), "-no-snapshot-load"]
      process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) {
        _, value in value
      }
      let logDirectory = root.appendingPathComponent(".ada/android-logs")
      try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
      let logURL = logDirectory.appendingPathComponent(UUID().uuidString + ".log")
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: logURL)
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      emulators[serial] = process
      await log(
        EditorProcessOutputEvent(
          stream: .standardOutput, text: "Starting Android emulator \(name). Log: \(logURL.path)\n")
      )
      do {
        for _ in 0..<120 {
          try Task.checkCancellation()
          guard process.isRunning else {
            throw EditorPreviewBuildFailure(
              message: "Android emulator exited before boot. See \(logURL.path).")
          }
          if let result = try? await execute(
            configuration.adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            configuration: configuration, at: root),
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
          {
            try handle.close()
            return serial
          }
          try await Task.sleep(for: .seconds(1))
        }
        throw EditorPreviewBuildFailure(
          message: "Android emulator did not finish booting. See \(logURL.path).")
      } catch {
        if process.isRunning { process.terminate() }
        emulators[serial] = nil
        try? handle.close()
        throw error
      }
    }

    func abi(serial: String, configuration: EditorAndroidConfiguration, at root: URL) async throws
      -> String
    {
      let value = try await execute(
        configuration.adb, ["-s", serial, "shell", "getprop", "ro.product.cpu.abi"],
        configuration: configuration, at: root)
      let abi = value.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      guard ["arm64-v8a", "x86_64"].contains(abi) else {
        throw EditorPreviewBuildFailure(
          message: "Android ABI \(abi) is unsupported. Use an ARM64 or x86_64 device.")
      }
      return abi
    }

    func launch(
      apk: URL, applicationID: String, serial: String, configuration: EditorAndroidConfiguration,
      at root: URL,
      requiresAOTReady: Bool = false,
      log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void = { _ in }
    ) async throws {
      _ = try await execute(
        configuration.adb, ["-s", serial, "install", "--no-incremental", "-r", apk.path],
        configuration: configuration, at: root, log: log)
      _ = try await execute(
        configuration.adb, ["-s", serial, "shell", "am", "force-stop", applicationID],
        configuration: configuration, at: root, log: log)
      _ = try await execute(
        configuration.adb,
        [
          "-s", serial, "shell", "am", "start", "-W", "-n",
          applicationID + "/android.app.NativeActivity",
        ], configuration: configuration, at: root, log: log)
      var processID = ""
      for _ in 0..<30 {
        try Task.checkCancellation()
        let pid = await runner.run(
          EditorProcessCommand(
            executablePath: configuration.adb,
            arguments: ["-s", serial, "shell", "pidof", applicationID], workingDirectory: root,
            environment: configuration.environment))
        if pid.succeeded {
          processID = pid.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
          if !processID.isEmpty { break }
        }
        try await Task.sleep(for: .milliseconds(300))
      }
      guard !processID.isEmpty else {
        throw EditorPreviewBuildFailure(
          message: "Android did not start \(applicationID). Check logcat.")
      }
      var ready = false
      for _ in 0..<45 {
        try Task.checkCancellation()
        let logs = try await execute(
          configuration.adb,
          ["-s", serial, "logcat", "-d", "--pid=" + processID, "-s", "AdaEngine:V"],
          configuration: configuration, at: root)
        if logs.standardOutput.contains("Android app failed:")
          || logs.standardOutput.contains("[AdaScript AOT] Startup failed:")
        {
          throw EditorPreviewBuildFailure(message: logs.standardOutput)
        }
        if logs.standardOutput.contains("Android frame loop started"),
          !requiresAOTReady || logs.standardOutput.contains("Native game ready")
        {
          ready = true
          break
        }
        _ = try await execute(
          configuration.adb, ["-s", serial, "shell", "pidof", applicationID],
          configuration: configuration, at: root)
        try await Task.sleep(for: .seconds(1))
      }
      guard ready else {
        throw EditorPreviewBuildFailure(
          message: "Android app did not finish engine startup. Check logcat for \(applicationID).")
      }
      await log(
        EditorProcessOutputEvent(
          stream: .standardOutput, text: "Android app running on \(serial), PID \(processID).\n"))
    }

    func stop(
      applicationID: String, serial: String, configuration: EditorAndroidConfiguration, at root: URL
    ) async throws {
      _ = try await execute(
        configuration.adb, ["-s", serial, "shell", "am", "force-stop", applicationID],
        configuration: configuration, at: root)
    }

    private func execute(
      _ executable: String, _ arguments: [String], configuration: EditorAndroidConfiguration,
      at root: URL,
      log: @Sendable @escaping (EditorProcessOutputEvent) async -> Void = { _ in }
    ) async throws -> EditorProcessResult {
      try Task.checkCancellation()
      let result = await runner.run(
        EditorProcessCommand(
          executablePath: executable, arguments: arguments, workingDirectory: root,
          environment: configuration.environment), output: log)
      try Task.checkCancellation()
      guard result.succeeded else {
        let message = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        throw EditorPreviewBuildFailure(
          message: message.isEmpty
            ? "Android command failed (\(result.exitCode)): \(arguments.joined(separator: " "))"
            : message)
      }
      return result
    }
  }
#endif
