import Foundation

struct EditorAdaScriptRuntimePluginDescriptor: Equatable, Identifiable, Sendable {
    let dependencies: [AdaProjectRuntimePluginID]
    let displayName: String
    let id: AdaProjectRuntimePluginID
}

struct EditorAdaScriptRuntimePluginSection: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let plugins: [AdaProjectRuntimePluginID]
    let sections: [Self]

    init(
        _ title: String,
        plugins: [AdaProjectRuntimePluginID] = [],
        sections: [Self] = []
    ) {
        self.id = title
        self.title = title
        self.plugins = plugins
        self.sections = sections
    }

    var allPluginIDs: [AdaProjectRuntimePluginID] {
        plugins + sections.flatMap(\.allPluginIDs)
    }
}

enum EditorAdaScriptRuntimePluginCatalog {
    static let descriptors: [EditorAdaScriptRuntimePluginDescriptor] = [
        .init(dependencies: [.upscale], displayName: "2D Rendering", id: .core2D),
        .init(dependencies: [.upscale], displayName: "3D Rendering", id: .core3D),
        .init(dependencies: [.core2D], displayName: "Sprites", id: .sprite),
        .init(dependencies: [.core2D], displayName: "2D Meshes", id: .mesh2D),
        .init(dependencies: [.core3D], displayName: "3D Models", id: .model3D),
        .init(dependencies: [.core2D, .mesh2D, .sprite], displayName: "2D Lighting", id: .light2D),
        .init(dependencies: [.core2D], displayName: "2D Physics", id: .physics2D),
        .init(dependencies: [.core3D], displayName: "3D Physics", id: .physics3D),
        .init(dependencies: [.core2D, .mesh2D, .sprite], displayName: "Tilemaps", id: .tilemap),
        .init(dependencies: [], displayName: "Audio", id: .audio),
        .init(dependencies: [], displayName: "Upscaling", id: .upscale),
    ]

    static let descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

    /// Organizes runtime capabilities by the subsystem they extend in Project Settings.
    static let settingsSections: [EditorAdaScriptRuntimePluginSection] = [
        .init(
            "Rendering",
            sections: [
                .init("2D", plugins: [.core2D, .sprite, .mesh2D, .light2D]),
                .init("3D", plugins: [.core3D, .model3D]),
            ]
        ),
        .init(
            "Simulation",
            sections: [
                .init("2D", plugins: [.physics2D, .tilemap]),
                .init("3D", plugins: [.physics3D]),
            ]
        ),
        .init("Platform", plugins: [.audio, .upscale]),
    ]

    static func presetPlugins(_ preset: AdaProjectRuntimePluginPreset) -> Set<AdaProjectRuntimePluginID> {
        switch preset {
        case .game2D:
            [.audio, .core2D, .light2D, .mesh2D, .physics2D, .sprite, .tilemap, .upscale]
        case .game3D:
            [.audio, .core3D, .model3D, .physics3D, .upscale]
        case .ui:
            [.core2D, .upscale]
        }
    }
}

struct EditorAdaScriptResolvedRuntimePlugins: Equatable, Sendable {
    let pluginIDs: [AdaProjectRuntimePluginID]
    let physics2DGravity: [Double]

    func contains(_ pluginID: AdaProjectRuntimePluginID) -> Bool {
        pluginIDs.contains(pluginID)
    }
}

enum EditorRuntimePluginResolutionError: Error, Equatable, LocalizedError, Sendable {
    case disabledDependency(plugin: String, requiredBy: String)
    case unsupportedPresetVersion(Int)
    case unknownPlugin(String)

    var errorDescription: String? {
        switch self {
        case let .disabledDependency(plugin, requiredBy):
            "Runtime plugin '\(plugin)' is disabled but required by '\(requiredBy)'."
        case let .unsupportedPresetVersion(version):
            "Runtime plugin preset version \(version) is not supported."
        case let .unknownPlugin(plugin):
            "Runtime plugin '\(plugin)' is not compiled into this AdaEditor build."
        }
    }
}

enum EditorAdaScriptRuntimePluginResolver {
    static func resolve(
        _ configuration: AdaProjectRuntimePlugins
    ) throws -> EditorAdaScriptResolvedRuntimePlugins {
        guard configuration.presetVersion == AdaProjectRuntimePlugins.currentPresetVersion else {
            throw EditorRuntimePluginResolutionError.unsupportedPresetVersion(configuration.presetVersion)
        }

        let enabled = Set(configuration.enable)
        let disabled = Set(configuration.disable)
        for pluginID in enabled.union(disabled).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard EditorAdaScriptRuntimePluginCatalog.descriptorByID[pluginID] != nil else {
                throw EditorRuntimePluginResolutionError.unknownPlugin(pluginID.rawValue)
            }
        }

        var resolved = EditorAdaScriptRuntimePluginCatalog.presetPlugins(configuration.preset)
        resolved.formUnion(enabled)
        resolved.subtract(disabled)

        var pending = Array(resolved)
        while let pluginID = pending.popLast() {
            guard let descriptor = EditorAdaScriptRuntimePluginCatalog.descriptorByID[pluginID] else {
                throw EditorRuntimePluginResolutionError.unknownPlugin(pluginID.rawValue)
            }
            for dependency in descriptor.dependencies {
                if disabled.contains(dependency) {
                    throw EditorRuntimePluginResolutionError.disabledDependency(
                        plugin: dependency.rawValue,
                        requiredBy: pluginID.rawValue
                    )
                }
                if resolved.insert(dependency).inserted {
                    pending.append(dependency)
                }
            }
        }

        let orderedPluginIDs = EditorAdaScriptRuntimePluginCatalog.descriptors
            .map(\.id)
            .filter(resolved.contains)
        return EditorAdaScriptResolvedRuntimePlugins(
            pluginIDs: orderedPluginIDs,
            physics2DGravity: configuration.settings.physics2D.gravity
        )
    }
}
