//
//  Sound.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/3/23.
//

import AdaUtils
import Math

public enum SoundState {
    case ready
    case playing
    case paused
    case stopped
    case finished
}

/// Interface describe sound object.
protocol Sound: AnyObject {
    var state: SoundState { get }

    var volume: Float { get set }

    var pitch: Float { get set }

    var position: Vector3 { get set }

    var isLooping: Bool { get set }

    func start()

    func stop()

    func pause()

    func copy() throws -> Sound

    func update(_ deltaTime: AdaUtils.TimeInterval)

    func onCompleteHandler(_ block: @escaping () -> Void)
}
