//
//  AssetsCodable.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/9/23.
//

import AdaUtils
import Foundation

// TODO: Mode for decoding/encoding files from/into binary format.

/// A query for an asset.
public struct AssetQuery: Sendable, Codable, Hashable {
    /// The name of the query.
    public let name: String

    /// The value of the query.
    public let value: String?
}

/// A meta information about an asset.
public struct AssetMeta: Sendable, Codable, Hashable {
    /// The file path of the asset.
    public let filePath: URL

    /// The query parameters of the asset.
    public let queryParams: [AssetQuery]

    /// The file name of the asset.
    public var fileName: String { self.filePath.lastPathComponent }
}

/// An error that occurs when decoding an asset.
public enum AssetDecodingError: LocalizedError {
    /// The invalid asset extension error.
    case invalidAssetExtension(String)

    /// The decoding problem error.
    case decodingProblem(String)

    /// The error description.
    public var errorDescription: String? {
        switch self {
        case let .invalidAssetExtension(string):
            return "[Asset Decoding Error] Invalid asset file extension \(string)"
        case let .decodingProblem(string):
            return "[Asset Decoding Error] Decoding finished with failure: \(string)"
        }
    }
}

// MARK: - Encoder -

/// A type that can encode itself to an external asset representation.
public protocol AssetEncoder: Sendable {
    /// - Returns: Meta information about asset.
    var assetMeta: AssetMeta { get }

    var encoder: (any Encoder)? { get }

    /// Use this method to encode content from asset.
    /// - Note: If you call this method more than once, than previous encode data will overwritten.
    func encode<T: Encodable>(_ value: T) throws

    func encode<A: Asset>(_ asset: A, to encoder: any Encoder) async throws
}

// MARK: - Decoder -

/// A type that can decode itself from external asset representation.
public protocol AssetDecoder: Sendable {
    /// - Returns: Meta information about asset.
    var assetMeta: AssetMeta { get }

    /// - Returns: asset file data.
    var assetData: Data { get }

    /// - Returns: decoder.
    var decoder: (any Decoder)? { get }

    /// Get or load a resource.
    ///
    /// - Parameter resourceType: The type of the resource.
    /// - Parameter path: The path to the resource.
    /// - Returns: The asset handle.
    func getOrLoadResource<A: Asset>(
        _ resourceType: A.Type,
        at path: String
    ) throws -> AssetHandle<A>

    /// Use this method to decode content from asset.
    ///
    /// - Parameter type: The type of the content.
    /// - Returns: The decoded content.
    func decode<T: Decodable>(_ type: T.Type) throws -> T

    /// Use this method to decode content from asset.
    ///
    /// - Parameter type: The type of the asset.
    /// - Parameter decoder: The decoder.
    /// - Returns: The decoded asset.
    func decode<A: Asset>(_ type: A.Type, from decoder: any Decoder) async throws -> A
}

// MARK: Asset Decoding Context

extension CodingUserInfoKey {
    /// Returns ``AssetDecodingContext`` object that contains information about resources
    public static let assetsDecodingContext = CodingUserInfoKey(rawValue: "org.adaengine.assetdecoder.context")
        .unwrap(message: "Asset decoder coding key is invalid.")

    /// Returns ``AssetEncodingContext`` object that contains information about resources
    public static let assetsEncodingContext = CodingUserInfoKey(rawValue: "org.adaengine.assetencoder.context")
        .unwrap(message: "Asset encoder coding key is invalid.")

    /// Returns ``AssetMeta`` object that contains information about resources
    public static let assetMetaInfo = CodingUserInfoKey(rawValue: "org.adaengine.assetsMetaInfo")
        .unwrap(message: "Asset metadata coding key is invalid.")
}

extension Decoder {
    /// Returns instance of asset decoding context if exists.
    /// - Warning: Only available if you save asset from AssetsManager
    public var assetsDecoder: AssetDecoder {
        guard let context = self.userInfo[.assetsDecodingContext] as? AssetDecoder else {
            fatalError("AssetDecodingContext info available if you save resouce from AssetsManager object.")
        }

        return context
    }

    /// Returns instance of asset meta
    /// - Warning: Only available if you save asset from AssetsManager
    public var assetMeta: AssetMeta {
        guard let meta = self.userInfo[.assetMetaInfo] as? AssetMeta else {
            fatalError("AssetMeta info available if you save resouce from AssetsManager object.")
        }

        return meta
    }
}

extension Encoder {
    /// Returns instance of asset meta
    /// /// - Warning: Only available if you load asset from AssetsManager
    public var assetMeta: AssetMeta {
        guard let meta = self.userInfo[.assetMetaInfo] as? AssetMeta else {
            fatalError("AssetMeta info available if you load resouce from AssetsManager object.")
        }

        return meta
    }

    /// Returns instance of asset encoding context if exists.
    /// - Warning: Only available if you save asset from AssetsManager
    public var assetsEncoder: AssetEncoder {
        guard let context = self.userInfo[.assetsEncodingContext] as? AssetEncoder else {
            fatalError("AssetEncodingContext info available if you save resouce from AssetsManager object.")
        }

        return context
    }
}
