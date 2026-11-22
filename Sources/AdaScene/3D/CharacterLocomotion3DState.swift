import Foundation
import Math

typealias Locomotion = CharacterLocomotion3DComponent

struct CharacterLocomotion3DRequest: Equatable, Sendable {
    let state: Locomotion.Phase
    let clip: String
    let speed: Double
    let activation: UInt64
}

extension Locomotion.Phase {
    var isGait: Bool { self == .walk || self == .run }
    var loops: Bool { self == .idle || isGait }
}

private enum LocomotionDirection: Int, CaseIterable, Sendable {
    case forward, right, back, left

    var angle: Float { Float(rawValue) * .pi / 2 }

    static func select(_ relativeAngle: Float, keeping current: Self?) -> Self {
        let angle = relativeAngle < 0 ? relativeAngle + 2 * .pi : relativeAngle
        if let current, abs(shortestTurn(relativeAngle - current.angle)) <= .pi * (55 / 180) {
            return current
        }
        // Preserve the clockwise tie after converting the owner's quaternion to yaw.
        let sector = Int((angle + .pi / 4 + 0.000001) / (.pi / 2)) % allCases.count
        return allCases[sector]
    }
}

private extension Locomotion.ForwardAxis {
    var angle: Float {
        switch self {
        case .positiveZ: 0
        case .positiveX: .pi / 2
        case .negativeZ: .pi
        case .negativeX: -.pi / 2
        }
    }
}

struct CharacterLocomotion3DMotion: Equatable, Sendable {
    private var gait: Locomotion.Phase = .idle
    private var direction: LocomotionDirection?
    private var waitingForFall = false
    private var remainingLandingTime: Double = 0
    private(set) var request: CharacterLocomotion3DRequest?

    mutating func advance(
        velocity: Vector3,
        grounded: Bool,
        deltaTime: Float,
        rotation: Quat,
        configuration: Locomotion.Configuration
    ) -> Quat? {
        let speed = (velocity.x * velocity.x + velocity.z * velocity.z).squareRoot()
        guard speed.isFinite, velocity.y.isFinite else {
            return nil
        }

        let previous = request
        let state = nextState(grounded: grounded, rising: velocity.y > 0.15, deltaTime: Double(deltaTime), configuration: configuration)
        if grounded, state.loops { updateGait(speed: speed) }
        let selectedState = grounded && state.loops ? gait : state

        let yaw = rotation.yaw
        let movementAngle = Math.atan2(velocity.x, velocity.z)
        let turn = shortestTurn(movementAngle - yaw - configuration.forwardAxis.angle)
        if selectedState == .idle {
            direction = nil
        } else if speed > 0.07, turn.isFinite, configuration.facingMode == .keepFacing, grounded, selectedState.isGait {
            direction = LocomotionDirection.select(turn, keeping: direction)
        }

        let clip = clipName(for: selectedState, configuration: configuration)
        var activation = previous?.activation ?? 0
        if previous?.state != selectedState || previous?.clip != clip { activation &+= 1 }
        request = .init(
            state: selectedState,
            clip: clip,
            speed: playbackSpeed(for: selectedState, speed: speed, configuration: configuration),
            activation: activation
        )

        guard configuration.facingMode == .turnToMovement, speed > 0.07, turn.isFinite, abs(turn) > 0.000001 else {
            return nil
        }
        let response = Float(1 - Foundation.exp(-12 * Double(deltaTime)))
        return Quat(axis: .up, angle: yaw + turn * response)
    }

    private mutating func nextState(
        grounded: Bool,
        rising: Bool,
        deltaTime: Double,
        configuration: Locomotion.Configuration
    ) -> Locomotion.Phase {
        let current = request?.state
        if grounded {
            waitingForFall = false
            switch current {
            case .jump, .fall:
                remainingLandingTime = configuration.landingDuration
                return .land
            case .land:
                remainingLandingTime -= deltaTime
                return remainingLandingTime > 0 ? .land : gait
            default:
                return gait
            }
        }

        switch current {
        case .fall: return .fall
        case .jump: return rising ? .jump : .fall
        default:
            if rising {
                return .jump
            }
            if current == nil || current == .land || waitingForFall {
                return .fall
            }
            waitingForFall = true
            return gait
        }
    }

    private mutating func updateGait(speed: Float) {
        if speed <= 0.07 || (gait == .idle && speed < 0.16) {
            gait = .idle
        } else if speed >= 2.475 || (gait == .run && speed > 2.1) {
            gait = .run
        } else {
            gait = .walk
        }
    }

    private func clipName(for state: Locomotion.Phase, configuration: Locomotion.Configuration) -> String {
        let directional: Locomotion.DirectionalGaits
        switch direction {
        case .left: directional = configuration.left
        case .right: directional = configuration.right
        case .back: directional = configuration.back
        default: directional = .init()
        }

        switch state {
        case .idle: return configuration.clips.idle
        case .walk: return directional.walk ?? configuration.clips.walk
        case .run: return directional.run ?? configuration.clips.run
        case .jump: return configuration.clips.jump
        case .fall: return configuration.clips.fall
        case .land: return configuration.clips.land
        }
    }

    private func playbackSpeed(for state: Locomotion.Phase, speed: Float, configuration: Locomotion.Configuration) -> Double {
        guard state.isGait else {
            return 1
        }
        let reference = state == .walk ? configuration.walkReferenceSpeed : configuration.runReferenceSpeed
        return Double(min(max(speed / reference, 0.25), 1.5))
    }
}

private extension Quat {
    var yaw: Float { Math.atan2(2 * (w * y + x * z), 1 - 2 * (x * x + y * y)) }
}

private func shortestTurn(_ angle: Float) -> Float {
    let turn = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if abs(abs(turn) - .pi) < 0.000001 {
        return .pi
    }
    if turn < -.pi {
        return turn + 2 * .pi
    }
    if turn > .pi {
        return turn - 2 * .pi
    }
    return turn
}
