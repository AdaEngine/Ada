//
//  DefaultAppWindow.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.12.2025.
//

import AdaApp
import Foundation

/// Create an empty window scene with attached ``DefaultPlugins``.
public struct DefaultAppWindow: AppScene {
    /// The file path to use for the `AssetsPlugin`.
    let filePath: StaticString
    let assetBundle: Bundle?

    public var body: some AppScene {
        EmptyWindow()
            .transformAppWorlds { world in
                world.insertPlugin(
                    DefaultPlugins(filePath: filePath, assetBundle: assetBundle),
                    after: MainSchedulerPlugin.self
                )
            }
    }

    /// - Parameter filePath: The file path to use for the `AssetsPlugin`.
    public init(filePath: StaticString = #filePath, assetBundle: Bundle? = nil) {
        self.filePath = filePath
        self.assetBundle = assetBundle
    }
}
