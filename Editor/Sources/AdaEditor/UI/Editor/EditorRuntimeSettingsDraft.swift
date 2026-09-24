import Foundation

struct EditorRuntimeSettingsDraft: Equatable, Sendable {
    var gravityX: String
    var gravityY: String
    var moduleName: String
    var scene: String
    var startupSystem: String
    var windowHeight: String
    var windowIsResizable: Bool
    var windowTitle: String
    var windowWidth: String

    init(runtime: AdaProjectRuntime = AdaProjectRuntime()) {
        let gravity = runtime.plugins.settings.physics2D.gravity
        self.gravityX = gravity.first.map { String($0) } ?? "0.0"
        self.gravityY = gravity.dropFirst().first.map { String($0) } ?? "-9.81"
        self.moduleName = runtime.moduleName
        self.scene = runtime.entry.scene ?? ""
        self.startupSystem = runtime.entry.startupSystem ?? ""
        self.windowHeight = String(runtime.window.size.height)
        self.windowIsResizable = runtime.window.isResizable
        self.windowTitle = runtime.window.title ?? ""
        self.windowWidth = String(runtime.window.size.width)
    }

    func applying(to runtime: AdaProjectRuntime) throws -> AdaProjectRuntime {
        guard let width = Int(windowWidth), width > 0 else {
            throw EditorRuntimeSettingsDraftError.invalidWindowWidth
        }
        guard let height = Int(windowHeight), height > 0 else {
            throw EditorRuntimeSettingsDraftError.invalidWindowHeight
        }
        guard
            let gravityX = Double(gravityX), gravityX.isFinite,
            let gravityY = Double(gravityY), gravityY.isFinite
        else {
            throw EditorRuntimeSettingsDraftError.invalidPhysicsGravity
        }

        var runtime = runtime
        runtime.moduleName = moduleName.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime.entry = AdaProjectRuntimeEntry(
            scene: scene.trimmedNilIfEmpty,
            startupSystem: startupSystem.trimmedNilIfEmpty,
            view: runtime.entry.view
        )
        runtime.plugins.settings.physics2D.gravity = [gravityX, gravityY]
        runtime.window = AdaProjectRuntimeWindow(
            title: windowTitle.trimmedNilIfEmpty,
            size: AdaProjectRuntimeWindowSize(width: width, height: height),
            isResizable: windowIsResizable
        )
        return runtime
    }
}

enum EditorRuntimeSettingsDraftError: Error, Equatable, LocalizedError, Sendable {
    case invalidPhysicsGravity
    case invalidWindowHeight
    case invalidWindowWidth

    var errorDescription: String? {
        switch self {
        case .invalidPhysicsGravity:
            "Physics2D gravity must contain two finite numbers."
        case .invalidWindowHeight:
            "Runtime window height must be a positive whole number."
        case .invalidWindowWidth:
            "Runtime window width must be a positive whole number."
        }
    }
}

extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
