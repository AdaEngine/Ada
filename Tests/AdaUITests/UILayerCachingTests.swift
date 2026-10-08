//
//  UILayerCachingTests.swift
//  AdaEngine
//

import AdaUtils
import Math
import Testing
@testable import AdaUI

@MainActor
struct UILayerCachingTests {

    @Test
    func unchangedCacheableLayerReusesRecordedDisplayList() throws {
        var recordingCount = 0
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 50)) { context, size in
            recordingCount += 1
            context.drawRect(Rect(origin: .zero, size: size), color: .white)
        }

        let firstContext = UIGraphicsContext()
        layer.drawLayer(in: firstContext)

        let secondContext = UIGraphicsContext()
        layer.drawLayer(in: secondContext)

        #expect(recordingCount == 1)

        let firstMarker = try #require(layerMarker(in: firstContext.getDrawCommands()))
        let secondMarker = try #require(layerMarker(in: secondContext.getDrawCommands()))
        #expect(firstMarker.id == secondMarker.id)
        #expect(firstMarker.version == secondMarker.version)
        #expect(firstMarker.isCacheable)
        #expect(secondMarker.isCacheable)
    }

    @Test
    func invalidatedLayerRecordsCommandsWithNewVersion() throws {
        var recordingCount = 0
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 50)) { context, size in
            recordingCount += 1
            context.drawRect(Rect(origin: .zero, size: size), color: .white)
        }

        let firstContext = UIGraphicsContext()
        layer.drawLayer(in: firstContext)
        let firstMarker = try #require(layerMarker(in: firstContext.getDrawCommands()))

        layer.invalidate()

        let secondContext = UIGraphicsContext()
        layer.drawLayer(in: secondContext)
        let secondMarker = try #require(layerMarker(in: secondContext.getDrawCommands()))

        #expect(recordingCount == 2)
        #expect(secondMarker.id == firstMarker.id)
        #expect(secondMarker.version == firstMarker.version + 1)
    }

    @Test
    func changedTransformRecordsCommandsWithNewVersion() throws {
        var recordingCount = 0
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 50)) { context, size in
            recordingCount += 1
            context.drawRect(Rect(origin: .zero, size: size), color: .white)
        }

        let firstContext = UIGraphicsContext()
        layer.drawLayer(in: firstContext)
        let firstMarker = try #require(layerMarker(in: firstContext.getDrawCommands()))

        var translatedContext = UIGraphicsContext()
        translatedContext.translateBy(x: 12, y: 8)
        layer.drawLayer(in: translatedContext)
        let translatedMarker = try #require(layerMarker(in: translatedContext.getDrawCommands()))

        #expect(recordingCount == 2)
        #expect(translatedMarker.id == firstMarker.id)
        #expect(translatedMarker.version == firstMarker.version + 1)
    }

    @Test
    func changedOpacityRecordsCommandsWithNewVersion() throws {
        var recordingCount = 0
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 50)) { context, size in
            recordingCount += 1
            context.drawRect(Rect(origin: .zero, size: size), color: .white)
        }

        let firstContext = UIGraphicsContext()
        layer.drawLayer(in: firstContext)
        let firstMarker = try #require(layerMarker(in: firstContext.getDrawCommands()))

        var translucentContext = UIGraphicsContext()
        translucentContext.opacity = 0.5
        layer.drawLayer(in: translucentContext)
        let translucentMarker = try #require(layerMarker(in: translucentContext.getDrawCommands()))

        #expect(recordingCount == 2)
        #expect(translucentMarker.id == firstMarker.id)
        #expect(translucentMarker.version == firstMarker.version + 1)
    }

    @Test
    func changedEnvironmentRecordsCommandsWithNewVersion() throws {
        var recordingCount = 0
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 50)) { context, size in
            recordingCount += 1
            context.drawRect(Rect(origin: .zero, size: size), color: .white)
        }

        let firstContext = UIGraphicsContext()
        layer.drawLayer(in: firstContext)
        let firstMarker = try #require(layerMarker(in: firstContext.getDrawCommands()))

        var changedContext = UIGraphicsContext()
        changedContext.environment[LayerCacheTestEnvironmentKey.self] = 1
        layer.drawLayer(in: changedContext)
        let changedMarker = try #require(layerMarker(in: changedContext.getDrawCommands()))

        #expect(recordingCount == 2)
        #expect(changedMarker.id == firstMarker.id)
        #expect(changedMarker.version == firstMarker.version + 1)
    }

    private func layerMarker(
        in commands: [UIGraphicsContext.DrawCommand]
    ) -> (id: UInt64, version: UInt64, isCacheable: Bool)? {
        for command in commands {
            if case let .beginLayer(id, version, isCacheable) = command {
                return (id, version, isCacheable)
            }
        }
        return nil
    }
}

private struct LayerCacheTestEnvironmentKey: EnvironmentKey {
    static let defaultValue = 0
}
