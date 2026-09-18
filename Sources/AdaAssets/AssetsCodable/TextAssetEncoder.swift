//
//  TextAssetEncoder.swift
//
//
//  Created by v.prusakov on 5/2/24.
//

import Foundation

#if !WASM
    import Yams
#endif

/// An encoder for assets that are stored in text format.
public final class TextAssetEncoder: AssetEncoder, @unchecked Sendable {
    /// The asset meta info of the encoder.
    public let assetMeta: AssetMeta
    /// The encoder of the encoder.
    public let encoder: (any Encoder)?

    /// The encoded data of the encoder.
    private(set) var encodedData: Data?

    /// Initialize a new text asset encoder.
    ///
    /// - Parameters:
    ///   - meta: The asset meta info of the encoder.
    ///   - encoder: The encoder of the encoder.
    init(meta: AssetMeta, encoder: (any Encoder)? = nil) {
        self.assetMeta = meta
        self.encoder = encoder
    }

    /// Encode a value to the encoder.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    /// - Throws: An error if the value cannot be encoded to the encoder.
    public func encode<T>(_ value: T) throws where T: Encodable {
        if let encoder {
            var container = encoder.singleValueContainer()
            try container.encode(value)
            return
        }

        if let data = value as? Data {
            self.encodedData = data
        } else {
            #if WASM
                let encoder = JSONEncoder()
            #else
                let encoder = YAMLEncoder()
                encoder.options.floatingPointNumberFormatStrategy = .decimal
            #endif
            let data = try encoder.encode(
                value,
                userInfo: [
                    .assetMetaInfo: self.assetMeta,
                    .assetsEncodingContext: self,
                ]
            )

            self.encodedData = data
        }
    }

    /// Encode an asset to the encoder.
    ///
    /// - Parameters:
    ///   - asset: The asset to encode.
    ///   - encoder: The encoder to encode the asset to.
    /// - Throws: An error if the asset cannot be encoded to the encoder.
    public func encode<A: Asset>(_ asset: A, to encoder: any Encoder) async throws {
        let newEncoder = Self(meta: self.assetMeta, encoder: encoder)
        try await asset.encodeContents(with: newEncoder)
    }
}

protocol AnyEncoder: Sendable {
    func encode<T: Encodable>(_ value: T, userInfo: [CodingUserInfoKey: any Sendable]) throws -> Data
}

#if !WASM
    extension YAMLEncoder: @unchecked @retroactive Sendable {}

    extension YAMLEncoder: AnyEncoder {
        func encode<T>(_ value: T, userInfo: [CodingUserInfoKey: any Sendable]) throws -> Data where T: Encodable {
            return try Data(self.encode(value, userInfo: userInfo).utf8)
        }
    }
#endif

extension JSONEncoder: AnyEncoder {
    func encode<T>(_ value: T, userInfo: [CodingUserInfoKey: any Sendable]) throws -> Data where T: Encodable {
        self.userInfo = userInfo
        return try self.encode(value)
    }
}
