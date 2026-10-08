//
//  LocalizedStringKey.swift
//  AdaEngine
//
//  Created by Codex on 18.06.2026.
//

import Foundation

/// A key used to look up localized text in a bundle string table.
public struct LocalizedStringKey: ExpressibleByStringLiteral, @unchecked Sendable {
    public let key: String
    public let table: String?
    public let bundle: Bundle

    public init(
        _ key: String,
        table: String? = nil,
        bundle: Bundle = .main
    ) {
        self.key = key
        self.table = table
        self.bundle = bundle
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }

    public func resolve() -> String {
        bundle.localizedString(
            forKey: key,
            value: key,
            table: table
        )
    }
}
