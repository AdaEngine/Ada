//
//  AdaEngineMacrosPlugin.swift
//  AdaEngineMacros
//
//  Created by v.prusakov on 2/14/24.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AdaEngineMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ComponentMacro.self,
        EntryMacro.self,
        SystemMacro.self,
        BundleMacro.self,
        PreviewableMacro.self,
        StateMacro.self,
    ]
}
