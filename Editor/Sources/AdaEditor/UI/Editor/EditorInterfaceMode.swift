import Foundation
import Observation

enum EditorInterfaceMode: String, CaseIterable, Sendable {
    case editor
    case agent

    var title: String { self == .editor ? "Editor" : "Agent" }
}

/// Presentation preferences never replace the editor's documents or agent session.
@MainActor
@Observable
final class EditorInterfaceState {
    var mode: EditorInterfaceMode {
        didSet { defaults.set(mode.rawValue, forKey: preferenceKey) }
    }
    var showsArtifact = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferenceKey: String

    init(projectPath: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let identity = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "default"
        preferenceKey = "AdaEditor.InterfaceMode." + identity
        mode = defaults.string(forKey: preferenceKey).flatMap(EditorInterfaceMode.init(rawValue:)) ?? .editor
    }
}
