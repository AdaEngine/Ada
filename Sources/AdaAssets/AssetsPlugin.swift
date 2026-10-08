//
//  AssetsPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.05.2025.
//

@_spi(Internal) import AdaApp
import AdaECS
import Foundation
import Logging

public struct AssetsPlugin: Plugin {
    private let filePath: StaticString
    private let assetBundleResourceURL: URL?

    public init(filePath: StaticString = #filePath, assetBundle: Bundle? = nil) {
        self.filePath = filePath
        self.assetBundleResourceURL = assetBundle.flatMap(Self.assetsResourceURL(in:))
    }

    /// Initializes assets from a runtime-selected directory.
    ///
    /// This entry point is used by document-backed AdaScript projects that do
    /// not have a Swift source location or resource bundle of their own.
    public init(assetDirectory: URL) {
        self.filePath = #filePath
        self.assetBundleResourceURL = assetDirectory.standardizedFileURL
    }

    public func setup(in app: AppWorlds) {
        do {
            try AssetsManager.initialize(
                filePath: filePath,
                assetBundleResourceURL: assetBundleResourceURL,
                scopeID: app.executionID
            )
            app.addSystem(AssetsProcessSystem.self, on: .preUpdate)
        } catch {
            Logger(label: "org.adaengine.AssetsPlugin").error("Setup failed with error: \(error)")
        }
    }

    private static func assetsResourceURL(in bundle: Bundle) -> URL {
        bundle.url(forResource: "Assets", withExtension: nil)
            ?? bundle.resourceURL
            ?? bundle.bundleURL
    }
}

@System
@inline(__always)
func AssetsProcess() {
    Task {
        do {
            try await AssetsManager.processResources()
        } catch {
            Logger(label: "org.adaengine.AssetsPlugin").error("Assets processing failed with error: \(error)")
        }
    }
}
