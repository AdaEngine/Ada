import Foundation

/// Declarative startup roots for an AdaScript project.
public struct AdaProjectRuntimeEntry: Codable, Equatable, Sendable {
    public var scene: String?
    public var startupSystem: String?
    public var view: String?

    public init(scene: String? = nil, startupSystem: String? = nil, view: String? = nil) {
        self.scene = scene
        self.startupSystem = startupSystem
        self.view = view
    }
}

/// A stable identifier for a native runtime capability compiled into AdaEditor.
public struct AdaProjectRuntimePluginID: Codable, Equatable, Hashable, RawRepresentable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let audio = Self(rawValue: "audio")
    public static let core2D = Self(rawValue: "core2d")
    public static let core3D = Self(rawValue: "core3d")
    public static let light2D = Self(rawValue: "light2d")
    public static let mesh2D = Self(rawValue: "mesh2d")
    public static let multiplayer = Self(rawValue: "multiplayer")
    public static let model3D = Self(rawValue: "model3d")
    public static let physics2D = Self(rawValue: "physics2d")
    public static let physics3D = Self(rawValue: "physics3d")
    public static let sprite = Self(rawValue: "sprite")
    public static let tilemap = Self(rawValue: "tilemap")
    public static let upscale = Self(rawValue: "upscale")

    public static let knownValues: Set<Self> = [
        .audio, .core2D, .core3D, .light2D, .mesh2D, .model3D,
        .multiplayer, .physics2D, .physics3D, .sprite, .tilemap, .upscale,
    ]
}

public enum AdaProjectRuntimePluginPreset: String, Codable, CaseIterable, Equatable, Sendable {
    case game2D = "game2d"
    case game3D = "game3d"
    case ui

    public var displayName: String {
        switch self {
        case .game2D: "2D Game"
        case .game3D: "3D Game"
        case .ui: "UI Application"
        }
    }
}

public struct AdaProjectPhysics2DSettings: Codable, Equatable, Sendable {
    public var gravity: [Double]

    public init(gravity: [Double] = [0, -9.81]) {
        self.gravity = gravity
    }
}

public struct AdaProjectMultiplayerSettings: Codable, Equatable, Sendable {
    public var buildIdentifier: String
    public var gameIdentifier: String
    public var host: String
    public var peerIndex: Int
    public var port: Int
    public var role: String

    public init(
        role: String = "host",
        host: String = "::1",
        port: Int = 37_777,
        peerIndex: Int = 1,
        gameIdentifier: String = "org.adaengine.adascript-game",
        buildIdentifier: String = "1"
    ) {
        self.buildIdentifier = buildIdentifier
        self.gameIdentifier = gameIdentifier
        self.role = role
        self.host = host
        self.port = port
        self.peerIndex = peerIndex
    }

    private enum CodingKeys: String, CodingKey {
        case buildIdentifier, gameIdentifier, host, peerIndex, port, role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buildIdentifier = try container.decodeIfPresent(String.self, forKey: .buildIdentifier) ?? "1"
        gameIdentifier = try container.decodeIfPresent(String.self, forKey: .gameIdentifier) ?? "org.adaengine.adascript-game"
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "::1"
        peerIndex = try container.decodeIfPresent(Int.self, forKey: .peerIndex) ?? 1
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 37_777
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "host"
    }
}

public struct AdaProjectRuntimePluginSettings: Codable, Equatable, Sendable {
    public var multiplayer: AdaProjectMultiplayerSettings
    public var physics2D: AdaProjectPhysics2DSettings

    public init(
        physics2D: AdaProjectPhysics2DSettings = AdaProjectPhysics2DSettings(),
        multiplayer: AdaProjectMultiplayerSettings = AdaProjectMultiplayerSettings()
    ) {
        self.physics2D = physics2D
        self.multiplayer = multiplayer
    }

    private enum CodingKeys: String, CodingKey {
        case multiplayer
        case physics2D = "physics2d"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        physics2D = try container.decodeIfPresent(AdaProjectPhysics2DSettings.self, forKey: .physics2D) ?? AdaProjectPhysics2DSettings()
        multiplayer = try container.decodeIfPresent(AdaProjectMultiplayerSettings.self, forKey: .multiplayer) ?? AdaProjectMultiplayerSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(physics2D, forKey: .physics2D)
        try container.encode(multiplayer, forKey: .multiplayer)
    }
}

public struct AdaProjectRuntimePlugins: Codable, Equatable, Sendable {
    public static let currentPresetVersion = 1

    public var disable: [AdaProjectRuntimePluginID]
    public var enable: [AdaProjectRuntimePluginID]
    public var preset: AdaProjectRuntimePluginPreset
    public var presetVersion: Int
    public var settings: AdaProjectRuntimePluginSettings

    public init(
        preset: AdaProjectRuntimePluginPreset = .game2D,
        presetVersion: Int = currentPresetVersion,
        enable: [AdaProjectRuntimePluginID] = [],
        disable: [AdaProjectRuntimePluginID] = [],
        settings: AdaProjectRuntimePluginSettings = AdaProjectRuntimePluginSettings()
    ) {
        self.preset = preset
        self.presetVersion = presetVersion
        self.enable = enable
        self.disable = disable
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case disable, enable, preset, presetVersion, settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        disable = try container.decodeIfPresent([AdaProjectRuntimePluginID].self, forKey: .disable) ?? []
        enable = try container.decodeIfPresent([AdaProjectRuntimePluginID].self, forKey: .enable) ?? []
        preset = try container.decodeIfPresent(AdaProjectRuntimePluginPreset.self, forKey: .preset) ?? .game2D
        presetVersion = try container.decodeIfPresent(Int.self, forKey: .presetVersion) ?? Self.currentPresetVersion
        settings = try container.decodeIfPresent(AdaProjectRuntimePluginSettings.self, forKey: .settings) ?? AdaProjectRuntimePluginSettings()
    }
}

public struct AdaProjectRuntimeWindowSize: Codable, Equatable, Sendable {
    public var height: Int
    public var width: Int

    public init(width: Int = 1024, height: Int = 700) {
        self.width = width
        self.height = height
    }
}

public struct AdaProjectRuntimeWindow: Codable, Equatable, Sendable {
    public var isResizable: Bool
    public var size: AdaProjectRuntimeWindowSize
    public var title: String?

    public init(
        title: String? = nil,
        size: AdaProjectRuntimeWindowSize = AdaProjectRuntimeWindowSize(),
        isResizable: Bool = true
    ) {
        self.title = title
        self.size = size
        self.isResizable = isResizable
    }
}

/// Runtime-owned project configuration for the precompiled AdaEditor host.
public struct AdaProjectRuntime: Codable, Equatable, Sendable {
    public var entry: AdaProjectRuntimeEntry
    public var moduleName: String
    public var plugins: AdaProjectRuntimePlugins
    public var window: AdaProjectRuntimeWindow

    public init(
        moduleName: String = "",
        entry: AdaProjectRuntimeEntry = AdaProjectRuntimeEntry(),
        plugins: AdaProjectRuntimePlugins = AdaProjectRuntimePlugins(),
        window: AdaProjectRuntimeWindow = AdaProjectRuntimeWindow()
    ) {
        self.moduleName = moduleName
        self.entry = entry
        self.plugins = plugins
        self.window = window
    }

    /// Compatibility initializer for schema v2 projects.
    public init(moduleName: String = "", entryView: String? = nil, startupScene: String? = nil) {
        self.init(
            moduleName: moduleName,
            entry: AdaProjectRuntimeEntry(scene: startupScene, view: entryView)
        )
    }

    /// Compatibility accessor for schema v2 `runtime.entryView`.
    public var entryView: String? {
        get { entry.view }
        set { entry.view = newValue }
    }

    /// Compatibility accessor for schema v2 `runtime.startupScene`.
    public var startupScene: String? {
        get { entry.scene }
        set { entry.scene = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case entry, moduleName, plugins, window
        case legacyEntryView = "entryView"
        case legacyStartupScene = "startupScene"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moduleName = try container.decodeIfPresent(String.self, forKey: .moduleName) ?? ""
        if let entry = try container.decodeIfPresent(AdaProjectRuntimeEntry.self, forKey: .entry) {
            self.entry = entry
        } else {
            self.entry = AdaProjectRuntimeEntry(
                scene: try container.decodeIfPresent(String.self, forKey: .legacyStartupScene),
                view: try container.decodeIfPresent(String.self, forKey: .legacyEntryView)
            )
        }
        plugins = try container.decodeIfPresent(AdaProjectRuntimePlugins.self, forKey: .plugins) ?? AdaProjectRuntimePlugins()
        window = try container.decodeIfPresent(AdaProjectRuntimeWindow.self, forKey: .window) ?? AdaProjectRuntimeWindow()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entry, forKey: .entry)
        try container.encode(moduleName, forKey: .moduleName)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(window, forKey: .window)
    }
}
