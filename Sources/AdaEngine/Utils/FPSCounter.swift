//
//  FPSCounter.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/28/23.
//

import Math

public class FPSCounter {
    private var lastNotificationTime: LongTimeInterval = 0
    private var notificationDelay: TimeInterval = 1.0
    private var numberOfFrames = 0

    public init() {}

    public func stop() {
        self.lastNotificationTime = 0
        self.numberOfFrames = 0
    }

    public func tick() {
        if self.lastNotificationTime == 0.0 {
            self.lastNotificationTime = Time.absolute
            return
        }

        self.numberOfFrames += 1

        let currentTime = Time.absolute
        let elapsedTime = TimeInterval(currentTime - self.lastNotificationTime)

        if elapsedTime >= self.notificationDelay {
            self.notifyUpdateForElapsedTime(elapsedTime)
            self.lastNotificationTime = 0.0
            self.numberOfFrames = 0
        }
    }

    private func notifyUpdateForElapsedTime(_ elapsedTime: TimeInterval) {
        let rounded = Math.round(Double(self.numberOfFrames) / Double(elapsedTime))
        let fps = Int(rounded)
        print(fps)
        EventManager.default.send(EngineEvents.FramesPerSecondEvent(framesPerSecond: fps))
    }
}
