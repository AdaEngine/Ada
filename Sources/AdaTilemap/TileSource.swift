//
//  TileSource.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/5/24.
//

import AdaUtils
import Math

/// A tile source.
public class TileSource: Codable, @unchecked Sendable {
    /// The invalid source id.
    static let invalidSource: Int = -1

    /// The tile set of the tile source.
    public internal(set) weak var tileSet: TileSet?

    /// The type alias for the tile source id.
    public typealias ID = Int

    /// The id of the tile source.
    public internal(set) var id: ID = TileSource.invalidSource

    /// The name of the tile source.
    public var name: String = ""

    /// Initialize a new tile source.
    public init() {}

    // MARK: - Codable

    /// Initialize a new tile source from a decoder.
    ///
    /// - Parameter decoder: The decoder to initialize the tile source from.
    /// - Throws: An error if the tile source cannot be initialized from the decoder.
    public required init(from _: any Decoder) throws {
        fatalErrorMethodNotImplemented()
    }

    /// Encode the tile source to an encoder.
    ///
    /// - Parameter encoder: The encoder to encode the tile source to.
    /// - Throws: An error if the tile source cannot be encoded to the encoder.
    public func encode(to _: any Encoder) throws {
        fatalErrorMethodNotImplemented()
    }

    // MARK: - Internal

    /// Get the tile data at the given atlas coordinates.
    ///
    /// - Parameter atlasCoordinates: The atlas coordinates to get the tile data at.
    /// - Returns: The tile data.
    func getTileData(at _: PointInt) -> TileData {
        fatalErrorMethodNotImplemented()
    }

    /// Set the tile source needs update.
    func setNeedsUpdate() {
        self.tileSet?.tileMap?.setNeedsUpdate()
    }

    // MARK: - Register

    /// The types of the tile sources.
    nonisolated(unsafe) private(set) static var types: [String: TileSource.Type] = [:]

    /// Call this function if you inherited from TileSource.
    public static func registerTileSource() {
        unsafe self.types[String(reflecting: self)] = Self.self
    }
}

struct TileData: Codable {
    enum CodingKeys: String, CodingKey {
        case modulateColor = "mColor"
        case flipH = "f_h"
        case flipV = "f_v"
        case occluderPolygon = "occ"
    }

    var modulateColor = Color(1.0, 1.0, 1.0, 1.0)
    var flipH: Bool = false
    var flipV: Bool = false
    /// Optional CCW polygon in tile **local** space for ``LightOccluder2D`` when the tile is spawned.
    var occluderPolygon: [Vector2]?
}
