//
//  MacroError.swift
//  AdaEngineMacro
//
//  Created by Vladislav Prusakov on 06.07.2024.
//

import SwiftDiagnostics
import SwiftSyntax

enum MacroError: Error, CustomStringConvertible {
    case macroUsage(String)

    var description: String {
        switch self {
        case let .macroUsage(text):
            return text
        }
    }
}
