//
//  DefaultPlugins.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/11/22.
//

import AdaApp
import AdaAudio
import AdaCorePipelines
import AdaECS
import AdaInput
import AdaPhysics
import AdaPlatform
import AdaScene
import AdaSprite
import AdaText
import AdaTilemap
import AdaTransform
import AdaUI
import Foundation
import OrderedCollections

/// Contains base configuration for any scene in the game.
/// This plugins will applied for each scene in Ada application and should be passed once per scene.
public struct DefaultPlugins: Plugin {
    private var plugins: OrderedDictionary<String, any Plugin>

    /// Initialize a new instance of `DefaultPlugins` with the given file path.
    /// - Parameter filePath: The file path to use for the `AssetsPlugin`.
    public init(filePath: StaticString = #filePath, assetBundle: Bundle? = nil) {
        var plugins = OrderedDictionary<String, any Plugin>()
        insertPlugin(TransformPlugin(), into: &plugins)
        insertPlugin(AppPlatformPlugin(), into: &plugins)
        insertPlugin(InputPlugin(), into: &plugins)
        insertPlugin(RenderWorldPlugin(), into: &plugins)
        insertPlugin(EventsPlugin(), into: &plugins)
        insertPlugin(CameraPlugin(), into: &plugins)
        insertPlugin(AssetsPlugin(filePath: filePath, assetBundle: assetBundle), into: &plugins)
        insertPlugin(VisibilityPlugin(), into: &plugins)
        insertPlugin(SpritePlugin(), into: &plugins)
        insertPlugin(Mesh2DPlugin(), into: &plugins)
        insertPlugin(TextPlugin(), into: &plugins)
        insertPlugin(ScenePlugin(), into: &plugins)
        insertPlugin(ScriptableObjectPlugin(), into: &plugins)
        insertPlugin(AudioPlugin(), into: &plugins)
        insertPlugin(WindowPlugin(), into: &plugins)
        insertPlugin(Core2DPlugin(), into: &plugins)
        insertPlugin(Core3DPlugin(), into: &plugins)
        insertPlugin(Light2DPlugin(), into: &plugins)
        insertPlugin(UpscalePlugin(), into: &plugins)
        insertPlugin(UIPlugin(), into: &plugins)
        insertPlugin(ContextMenuPlugin(), into: &plugins)
        insertPlugin(Physics2DPlugin(), into: &plugins)
        insertPlugin(TileMapPlugin(), into: &plugins)
        self.plugins = plugins
    }

    public func setup(in app: AppWorlds) {
        for plugin in plugins.elements.values {
            app.addPlugin(plugin)
        }
    }

    /// Set a plugin.
    /// - Parameter plugin: The plugin to set.
    /// - Returns: A new instance of `DefaultPlugins` with the plugin set.
    public func set<T: Plugin>(_ plugin: T) -> Self {
        var newValue = self
        insertPlugin(plugin, into: &newValue.plugins)
        return newValue
    }

    /// Disable a plugin.
    /// - Parameter plugin: The plugin to disable.
    /// - Returns: A new instance of `DefaultPlugins` with the plugin disabled.
    public func disable<T: Plugin>(_: T.Type) -> Self {
        var newValue = self
        newValue.plugins[String(reflecting: T.self)] = nil
        return newValue
    }
}

private func insertPlugin<T: Plugin>(
    _ plugin: T,
    into dictionary: inout OrderedDictionary<String, any Plugin>
) {
    dictionary[String(reflecting: T.self)] = plugin
}
