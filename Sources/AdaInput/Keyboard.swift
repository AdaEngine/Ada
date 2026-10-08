//
//  File.swift
//
//
//  Created by v.prusakov on 5/1/24.
//

import AdaUtils
import Foundation

open class Keyboard {
    public typealias KeyCodeHashMap = [UInt16: KeyCode]
    public typealias OSKeyCodeHashMap = [KeyCode: UInt16]

    public private(set) var keycodes: KeyCodeHashMap = [:]
    public private(set) var keycodesInverse: OSKeyCodeHashMap = [:]

    public init() {
        self.initialize(keycodes: &keycodes)

        for (osKey, keyCode) in keycodes {
            keycodesInverse[keyCode] = osKey
        }
    }

    open func initialize(keycodes _: inout KeyCodeHashMap) {
        fatalErrorMethodNotImplemented()
    }
}
