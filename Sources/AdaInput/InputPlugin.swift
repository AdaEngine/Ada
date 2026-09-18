//
//  InputPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.05.2025.
//

import AdaApp
import AdaECS
import Foundation
import Logging
import Math

/// The Input plugin handle system input events and ``Input`` resource to the world.
public struct InputPlugin: Plugin {
    @Local private var controllerEngine: GameControllerEngine?

    private let actions: [InputAction]?

    /// Uses an explicit map, or loads `.ada/project.json` from the working directory for Swift games.
    public init(actions: [InputAction]? = nil) {
        self.actions = actions
    }

    public func setup(in app: AppWorlds) {
        #if canImport(Darwin)
            let appleGameControllerManager = AppleGameControllerManager()
            controllerEngine = appleGameControllerManager
        #else
            controllerEngine = nil
        #endif

        var input = Input(gameControllerEngine: controllerEngine)
        do {
            if let actions {
                try input.setInputActions(actions)
            } else {
                let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".ada/project.json")
                if FileManager.default.fileExists(atPath: url.path) {
                    struct ProjectInput: Decodable { var inputActions: [InputAction]? }
                    let project = try JSONDecoder().decode(ProjectInput.self, from: Data(contentsOf: url))
                    try input.setInputActions(project.inputActions ?? [])
                }
            }
        } catch {
            Logger(label: "org.adaengine.AdaInput").error("Unable to load input actions: \(error.localizedDescription)")
        }
        app
            .insertResource(input)
            .addSystem(InputStartupSystem.self, on: .startup)
            .addSystem(InputEventParseSystem.self, on: .preUpdate)
            .addSystem(InputEventsCleanupSystem.self, on: .postUpdate)
    }

    public func destroy(for _: borrowing AppWorlds) {
        controllerEngine?.stopMonitoring()
    }
}

@PlainSystem
public struct InputEventParseSystem {
    @ResMut<Input>
    private var input

    private let logger = Logger(label: "org.adaengine.AdaInput")

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        input.beginActionFrame()
        input.flushPendingEvents()
        for event in input.eventsPool {
            switch event {
            case let keyEvent as KeyEvent:
                if keyEvent.keyCode == .none && keyEvent.isRepeated {
                    continue
                }

                if keyEvent.status == .down {
                    input.keyEvents.insert(keyEvent.keyCode)
                } else {
                    input.keyEvents.remove(keyEvent.keyCode)
                }
            case let mouseEvent as MouseEvent:
                input.mouseEvents[mouseEvent.button] = mouseEvent
                if mouseEvent.button == .scrollWheel, mouseEvent.scrollDelta.y != 0 {
                    input.actionScrollDirections.insert(mouseEvent.scrollDelta.y > 0 ? .positive : .negative)
                }
                if mouseEvent.button != .scrollWheel, mouseEvent.phase == .changed {
                    input.actionMouseMoved = true
                }
            case let touchEvent as TouchEvent:
                input.touches = input.touches.filter {
                    $0.contactID != touchEvent.contactID || $0.window != touchEvent.window
                }
                switch touchEvent.phase {
                case .began,
                    .moved:
                    input.touches.insert(touchEvent)
                case .ended,
                    .cancelled:
                    break
                }
                switch touchEvent.phase {
                case .began: input.actionTouchPhases.insert(.began)
                case .moved: input.actionTouchPhases.insert(.moved)
                case .ended: input.actionTouchPhases.insert(.ended)
                case .cancelled: input.actionTouchPhases.insert(.cancelled)
                }
            case let keyboardEvent as KeyboardEvent:
                input.keyboardState = Input.KeyboardState(event: keyboardEvent)
            case let gamepadConnectionEvent as GamepadConnectionEvent:
                if gamepadConnectionEvent.isConnected {
                    let controllerType = gamepadConnectionEvent.gamepadInfo?.type ?? "Unknown"
                    let controllerName = gamepadConnectionEvent.gamepadInfo?.name ?? "Unknown"

                    input.gamepads[gamepadConnectionEvent.gamepadId] = Gamepad(
                        gamepadId: gamepadConnectionEvent.gamepadId,
                        info: gamepadConnectionEvent.gamepadInfo,
                        gameControllerEngine: input.gameControllerEngine
                    )

                    logger.info("Gamepad connected: ID \(gamepadConnectionEvent.gamepadId), Name: \(controllerName), Type: \(controllerType)")
                } else {
                    input.gamepads.removeValue(forKey: gamepadConnectionEvent.gamepadId)
                    logger.info("Gamepad disconnected: ID \(gamepadConnectionEvent.gamepadId)")
                }
            case let gamepadButtonEvent as GamepadButtonEvent:
                guard var gamepadState = input.gamepads[gamepadButtonEvent.gamepadId] else {
                    continue
                }

                if gamepadButtonEvent.isPressed {
                    gamepadState.buttonsPressed.insert(gamepadButtonEvent.button)
                } else {
                    gamepadState.buttonsPressed.remove(gamepadButtonEvent.button)
                }
                input.gamepads[gamepadButtonEvent.gamepadId] = gamepadState
            case let gamepadAxisEvent as GamepadAxisEvent:
                guard var gamepadState = input.gamepads[gamepadAxisEvent.gamepadId] else {
                    continue
                }

                gamepadState.axisValues[gamepadAxisEvent.axis] = gamepadAxisEvent.value
                input.gamepads[gamepadAxisEvent.gamepadId] = gamepadState
            default:
                break
            }
            input.updateActionStates()
        }
    }
}

@System
@inline(__always)
@MainActor
func InputEventsCleanup(
    _ input: ResMut<Input>
) {
    input.wrappedValue.removeEvents()
}

@System
@inline(__always)
public func InputStartup(
    _ input: ResMut<Input>
) async {
    input.wrappedValue.gameControllerEngine?.startMonitoring()

    guard let stream = input.wrappedValue.gameControllerEngine?.makeEventStream() else {
        return
    }
    Task { @MainActor in
        for await event in stream {
            input.wrappedValue.receiveEvent(event)
        }
    }
}
