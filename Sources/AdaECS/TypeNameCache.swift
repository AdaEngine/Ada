//
//  TypeNameCache.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.04.2026.
//

import Foundation

enum TypeNameCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: String] = [:]

    static func name(for type: Any.Type) -> String {
        let id = ObjectIdentifier(type)
        lock.lock()
        defer { lock.unlock() }

        if let cached = unsafe cache[id] {
            return cached
        }
        let name = _typeName(type, qualified: true)
        unsafe cache[id] = name
        return name
    }
}
