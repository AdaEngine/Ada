//
//  System+Runtime.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/24/22.
//

import Foundation

// We should register our systems in engine, because we should initiate them in memory
// TODO: (Vlad) Add system list to editor and generate file with registred systems.
extension System {
    static var swiftName: String {
        TypeNameCache.name(for: self)
    }
}
