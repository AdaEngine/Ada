import AdaEngine
import AdaPlayerConnect
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

struct AdaPlayerApp: App {
    var body: some AppScene {
        WindowGroup { AdaPlayerHomeView() }
            .windowTitle("AdaPlayer")
            .windowMode(.windowed)
            .minimumSize(width: 320, height: 480)
    }
}

@Observable @MainActor
final class AdaPlayerController {
    let host = PlayerHost()
    struct Session {
        let id = UUID()
        let view: EditorAdaScriptProjectRuntimeView
        let directory: URL
    }
    var runtime: Session?
    var startupError: String?
    private var logTask: Task<Void, Never>?
    private var lifecycleTasks: [Task<Void, Never>] = []

    func watchLifecycle() {
        #if canImport(UIKit)
            guard lifecycleTasks.isEmpty else {
                return
            }
            lifecycleTasks = [
                Task { [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification).map({ _ in true }) {
                        self?.shutdown()
                    }
                },
                Task { [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification).map({ _ in true }) {
                        self?.start()
                    }
                },
            ]
        #endif
    }

    func close() {
        lifecycleTasks.forEach { $0.cancel() }
        lifecycleTasks = []
        shutdown()
    }

    func start() {
        guard logTask == nil else {
            return
        }
        startupError = nil
        host.onDeploy = { [weak self] snapshot in
            let prepared = try await Self.prepare(snapshot)
            guard let self, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: prepared.directory)
                throw CancellationError()
            }
            do {
                let runtime = try EditorAdaScriptProjectRuntimeView(artifact: prepared.artifact)
                self.stop()
                self.runtime = Session(view: runtime, directory: prepared.directory)
            } catch {
                try? FileManager.default.removeItem(at: prepared.directory)
                throw error
            }
        }
        host.onStop = { [weak self] in self?.stop() }
        do {
            #if canImport(UIKit)
                let name = UIDevice.current.name
            #else
                let name = Host.current().localizedName ?? "AdaPlayer"
            #endif
            try host.start(name: name)
        } catch {
            startupError = error.localizedDescription
            return
        }
        RuntimeLogStore.shared.setEnabled(true)
        logTask = Task { [weak self] in
            var cursor = RuntimeLogStore.shared.read(after: Int.max, limit: 1).nextCursor
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else {
                    return
                }
                let batch = RuntimeLogStore.shared.read(after: cursor, limit: 100)
                cursor = batch.nextCursor
                guard self.host.isPaired else {
                    continue
                }
                do {
                    if batch.dropped > 0 {
                        try await self.host.send(PlayerMessage(.log, text: "[warning] \(batch.dropped) log entries dropped."))
                    }
                    for entry in batch.entries {
                        try await self.host.send(PlayerMessage(.log, text: "[\(entry.level)] \(entry.label): \(entry.message)"))
                    }
                } catch { self.host.disconnect() }
            }
        }
    }

    func stop() {
        runtime = nil
    }

    func shutdown() {
        logTask?.cancel()
        logTask = nil
        host.shutdown()
        stop()
    }

    @concurrent private static func prepare(_ snapshot: PlayerProjectSnapshot) async throws -> Prepared {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("AdaPlayerSessions", isDirectory: true)
        let directory = try snapshot.install(in: cache)
        do {
            let project = try ProjectSystem.loadProject(at: directory)
            try ProjectSystem.validateRunCompatibility(of: project, at: directory, destination: .iPadOS)
            let artifact = try EditorAdaScriptProjectBuilder().prepare(project: project, at: directory)
            return Prepared(directory: directory, artifact: artifact)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private struct Prepared: Sendable {
        let directory: URL
        let artifact: EditorAdaScriptProjectBuildArtifact
    }
}

private struct AdaPlayerHomeView: View {
    @State private var controller = AdaPlayerController()

    var body: some View {
        ZStack {
            Color.black
            if let runtime = controller.runtime {
                runtime.view.id(runtime.id)
                    .onDisappear { try? FileManager.default.removeItem(at: runtime.directory) }
            } else {
                VStack(spacing: 24) {
                    Text("AdaPlayer").font(.system(size: 32, weight: .bold))
                    Text(controller.startupError ?? controller.host.status).font(.system(size: 16))
                    if !controller.host.isPaired {
                        Text(controller.host.code).font(.system(size: 42, weight: .bold))
                            .accessibilityIdentifier("AdaPlayer.PairingCode")
                        Text("On the same Wi-Fi, choose AdaPlayer in AdaEditor and press Run. Enter this code to connect.")
                            .font(.system(size: 16))
                    }
                    Button("Restart connection") {
                        controller.shutdown()
                        controller.start()
                    }
                }
                .padding(.all, 28)
                .frame(maxWidth: 520)
                .foregroundColor(.white)
            }
            if controller.host.isPaired {
                VStack {
                    HStack {
                        Spacer()
                        Button("Disconnect") { controller.host.disconnect() }
                            .padding(.all, 12)
                            .background(.black.opacity(0.7))
                            .foregroundColor(.white)
                            .accessibilityIdentifier("AdaPlayer.Disconnect")
                    }
                    Spacer()
                }
                .padding(.all, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            controller.watchLifecycle()
            controller.start()
        }
        .onDisappear { controller.close() }
    }
}
