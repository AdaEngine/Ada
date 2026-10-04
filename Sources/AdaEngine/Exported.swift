//
//  Exported.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/31/22.
//

// File contains all exported frameworks, to avoid import this libs in client side.
// Like example, user can use Math library if he/she use imported only `AdaEngine`.
// Can be problem if swift deprecate this @_exported hack.

@_exported import AdaAnimation
@_exported import AdaApp
@_exported import AdaAssets
@_exported import AdaAudio
@_exported import AdaCorePipelines
@_exported import AdaECS
@_exported import AdaInput
@_exported import AdaPhysics
@_exported import AdaPlatform
@_exported import AdaRender
@_exported import AdaScene
@_exported import AdaScripting
@_exported import AdaSpatial
@_exported import AdaSprite
@_exported import AdaText
@_exported import AdaTilemap
@_exported import AdaTransform
@_exported import AdaUI
@_exported import AdaUtils
@_exported import Foundation
@_exported import Math

public typealias TimeInterval = AdaUtils.TimeInterval
