//
//  AudioResource.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/6/23.
//

import AdaAssets
import AdaUtils
import Foundation

/// An audio resource that can be played.
/// The AudioResource class stores audio data that you can play in your scene or entire app.
public final class AudioResource: Asset, @unchecked Sendable {
    public var assetMetaInfo: AssetMetaInfo?

    private var sound: Sound

    public required init(from decoder: AssetDecoder) async throws {
        if Self.extensions().contains(where: { decoder.assetMeta.filePath.pathExtension == $0 }) {
            self.sound = unsafe try AudioServer.shared.engine.makeSound(from: decoder.assetData)
        } else {
            self.sound = unsafe try AudioServer.shared.engine.makeSound(from: decoder.assetMeta.filePath)
        }
    }

    public static func extensions() -> [String] {
        ["audiores"]
    }

    private init(sound: Sound) {
        self.sound = sound
    }

    public func encodeContents(with _: AssetEncoder) throws {
        fatalErrorMethodNotImplemented()
    }

    // TODO: (Vlad) I'm not sure that is a good solution to copy sound.
    /// Returns copy of sound.
    internal func getSound() throws -> Sound {
        return try self.sound.copy()
    }

    // MARK: - Public

    /// Create a new instance of audio resource from a file.
    /// - Note: Supports `WAV` format.
    public static func create(from url: URL) throws -> AudioResource {
        let sound = unsafe try AudioServer.shared.engine.makeSound(from: url)
        return AudioResource(sound: sound)
    }

    /// Create a new instance of audio resource from a data.
    public static func create(from data: Data) throws -> AudioResource {
        let sound = unsafe try AudioServer.shared.engine.makeSound(from: data)
        return AudioResource(sound: sound)
    }
}
