import Foundation

extension ProjectSystem {
    static func validateRuntimePlugins(_ plugins: AdaProjectRuntimePlugins) throws(ProjectSystemError) {
        guard plugins.presetVersion == AdaProjectRuntimePlugins.currentPresetVersion else {
            throw .invalidField(
                path: "runtime.plugins.presetVersion",
                message: "Unsupported plugin preset version \(plugins.presetVersion)."
            )
        }
        let enabled = Set(plugins.enable)
        let disabled = Set(plugins.disable)
        guard enabled.count == plugins.enable.count else {
            throw .invalidField(path: "runtime.plugins.enable", message: "Plugin identifiers must be unique.")
        }
        guard disabled.count == plugins.disable.count else {
            throw .invalidField(path: "runtime.plugins.disable", message: "Plugin identifiers must be unique.")
        }
        if let unknown = enabled.union(disabled)
            .subtracting(AdaProjectRuntimePluginID.knownValues)
            .min(by: { $0.rawValue < $1.rawValue }) {
            throw .invalidField(path: "runtime.plugins", message: "Unknown runtime plugin '\(unknown.rawValue)'.")
        }
        if let overlap = enabled.intersection(disabled).min(by: { $0.rawValue < $1.rawValue }) {
            throw .invalidField(
                path: "runtime.plugins",
                message: "Runtime plugin '\(overlap.rawValue)' cannot be both enabled and disabled."
            )
        }
        let gravity = plugins.settings.physics2D.gravity
        guard gravity.count == 2, gravity.allSatisfy(\.isFinite) else {
            throw .invalidField(
                path: "runtime.plugins.settings.physics2d.gravity",
                message: "Physics2D gravity must contain two finite numbers."
            )
        }
        let multiplayer = plugins.settings.multiplayer
        guard ["host", "peer"].contains(multiplayer.role) else {
            throw .invalidField(
                path: "runtime.plugins.settings.multiplayer.role",
                message: "Multiplayer role must be host or peer."
            )
        }
        guard (1...65_535).contains(multiplayer.port) else {
            throw .invalidField(
                path: "runtime.plugins.settings.multiplayer.port",
                message: "Multiplayer port must be between 1 and 65535."
            )
        }
        guard (1...255).contains(multiplayer.peerIndex) else {
            throw .invalidField(
                path: "runtime.plugins.settings.multiplayer.peerIndex",
                message: "Multiplayer peerIndex must be between 1 and 255."
            )
        }
    }

    static func validateRuntimeWindow(_ window: AdaProjectRuntimeWindow) throws(ProjectSystemError) {
        let size = window.size
        guard (1...16_384).contains(size.width) else {
            throw .invalidField(path: "runtime.window.size.width", message: "Window width must be between 1 and 16384.")
        }
        guard (1...16_384).contains(size.height) else {
            throw .invalidField(path: "runtime.window.size.height", message: "Window height must be between 1 and 16384.")
        }
    }
}
