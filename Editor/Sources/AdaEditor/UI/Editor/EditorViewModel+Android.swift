import Foundation

struct EditorAndroidRunSession: Sendable {
  let applicationID: String
  let serial: String
  let projectURL: URL
  let configuration: EditorAndroidConfiguration
}

extension EditorAndroidConfiguration {
  static var studioEngineRoot: URL {
    #if os(macOS)
      if let executable = Bundle.main.executableURL,
        let bundle = EditorBuildSDK.appBundle(containing: executable)
      {
        return bundle.appendingPathComponent("Contents/Resources/BuildSDK/AdaEngine")
      }
    #endif
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

extension EditorViewModel {
  func refreshAndroidTargets() {
    #if os(macOS)
      androidDiscoveryTask?.cancel()
      let configuration = androidConfiguration
      let root = projectURL ?? FileManager.default.homeDirectoryForCurrentUser
      androidStatus = "Looking for Android devices and emulators…"
      androidDiscoveryTask = Task { [weak self] in
        guard let self else { return }
        do {
          let targets = try await EditorAndroidTools().discover(
            configuration: configuration, at: root)
          guard !Task.isCancelled, self.androidConfiguration == configuration else { return }
          androidTargets = targets
          if !targets.contains(where: { $0.id == selectedAndroidTargetID }),
            targets.filter(\.isAvailable).count == 1
          {
            selectedAndroidTargetID = targets.first(where: \.isAvailable)?.id
          }
          androidStatus =
            targets.isEmpty
            ? "No Android devices or AVDs. Create an emulator in Android Studio or connect a device with USB debugging."
            : "\(targets.count) Android destinations"
        } catch {
          guard !Task.isCancelled else { return }
          androidTargets = []
          androidStatus = "Android discovery failed: \(error.localizedDescription)"
        }
        androidDiscoveryTask = nil
      }
    #else
      androidStatus = "Android export and device launch require standalone macOS Ada Studio."
    #endif
  }

  func selectAndroidTarget(_ target: EditorAndroidTarget) {
    selectedAndroidTargetID = target.id
    selectRunDestination(.android)
  }

  func exportAndroidProject(launch: Bool = false) {
    #if os(macOS)
      guard workspaceTask == nil, let projectURL else { return }
      guard EditorDistribution.current.supportsSwiftProjects else {
        appendOutput("Android export requires standalone macOS Ada Studio.")
        return
      }
      guard workbench.saveAllDocuments() else {
        appendOutput("Android export blocked: project documents could not be saved.")
        return
      }
      let target = androidTargets.first { $0.id == selectedAndroidTargetID }
      guard !launch || target?.isAvailable == true else {
        appendOutput("Select an authorized Android device or emulator from Run Destination.")
        refreshAndroidTargets()
        return
      }
      let title = launch ? "Build and Run on Android" : "Export Android APK"
      let activity = beginWorkspaceActivity(title: title, source: .build)
      workspaceStatus = .running(title)
      buildActivity = EditorBuildActivity(title: title)
      footer.setWorkspaceFooterTitle(title)
      let runner = EditorProcessRunner()
      androidRunner = runner
      let tools = EditorAndroidTools(runner: runner)
      androidTools = tools
      let configuration = androidConfiguration
      let product = selectedRunProduct
      workspaceTask = Task { [weak self] in
        guard let self else { return }
        let log: @Sendable (EditorProcessOutputEvent) async -> Void = { [weak self] event in
          await MainActor.run { self?.appendOutputBlock(event.text) }
        }
        do {
          let project = try ProjectSystem.loadProject(at: projectURL)
          let sdk = try EditorBuildSDK.locate()
          try configuration.validateBuildTools(engineRoot: sdk.engineRoot)
          let serial: String?
          let abi: String
          if let target, launch {
            serial = try await tools.resolve(
              target, configuration: configuration, at: projectURL, log: log)
            abi = try await tools.abi(
              serial: serial ?? "", configuration: configuration, at: projectURL)
          } else {
            serial = nil
            abi = "arm64-v8a"
          }
          let output = projectURL.appendingPathComponent("Exports/Android")
          let result = try await EditorAndroidProjectExporter(runner: runner).export(
            project: project, at: projectURL, to: output,
            sdk: sdk, configuration: configuration, abi: abi, product: product, log: log)
          let apk = try EditorAndroidProjectExporter.apk(in: result)
          appendOutput("Android APK ready: \(apk.path)")
          if let serial {
            let applicationID = EditorAndroidConfiguration.applicationID(
              for: project.project.name ?? projectURL.lastPathComponent)
            try await tools.launch(
              apk: apk, applicationID: applicationID, serial: serial, configuration: configuration,
              at: projectURL, requiresAOTReady: project.build.system.isAdaScript, log: log)
            androidRunningSession = EditorAndroidRunSession(
              applicationID: applicationID, serial: serial, projectURL: projectURL,
              configuration: configuration)
            workspaceStatus = .running("Android · \(target?.name ?? serial)")
          } else {
            workspaceStatus = .ready
            _ = EditorPlatformFileActions.reveal(apk)
          }
          buildActivity?.finish(succeeded: true)
          finishWorkspaceActivity(activity, succeeded: true)
        } catch is CancellationError {
          workspaceStatus = .cancelled
          buildActivity?.finish(succeeded: false)
          finishWorkspaceActivity(activity, succeeded: false, detail: "Cancelled")
        } catch {
          appendOutput("Android export/run failed: \(error.localizedDescription)")
          workspaceStatus = .failed(error.localizedDescription)
          buildActivity?.finish(succeeded: false)
          finishWorkspaceActivity(activity, succeeded: false, detail: error.localizedDescription)
        }
        footer.setWorkspaceFooterTitle(workspaceStatus.title)
        workspaceTask = nil
        androidRunner = nil
      }
    #else
      appendOutput("Android export and device launch require standalone macOS Ada Studio.")
    #endif
  }

  func stopAndroidRun() {
    #if os(macOS)
      guard let session = androidRunningSession else { return }
      androidRunningSession = nil
      Task { [weak self] in
        do {
          try await EditorAndroidTools().stop(
            applicationID: session.applicationID, serial: session.serial,
            configuration: session.configuration, at: session.projectURL)
          self?.workspaceStatus = .ready
          self?.appendOutput("Stopped Android game on \(session.serial).")
        } catch {
          self?.workspaceStatus = .failed(error.localizedDescription)
          self?.appendOutput("Could not stop the Android game: \(error.localizedDescription)")
        }
        self?.footer.setWorkspaceFooterTitle(self?.workspaceStatus.title ?? "Android")
      }
    #endif
  }
}
