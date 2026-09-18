//
//  ExportCodable.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/22/23.
//

public typealias _ExportCodable = _ExportDecodable & _ExportEncodable

/// Helper to avoid generics problems
public protocol _ExportDecodable {
    typealias DecodingContainer = KeyedDecodingContainer<CodingName>
    func decode(from container: DecodingContainer, propertyName: String, userInfo: [CodingUserInfoKey: Any]) throws
}

public protocol _ExportEncodable {
    typealias EncodingContainer = KeyedEncodingContainer<CodingName>
    func encode(to container: inout EncodingContainer, propertyName: String, userInfo: [CodingUserInfoKey: Any]) throws
}

public struct CodingName: CodingKey {
    public var stringValue: String

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    public var intValue: Int?

    public init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

extension CodingName {
    public static let editor = CodingName(stringValue: "_editor")
    public static let value = CodingName(stringValue: "_value")
}
