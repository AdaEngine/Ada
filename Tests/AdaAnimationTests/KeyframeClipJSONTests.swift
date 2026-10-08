//
//  KeyframeClipJSONTests.swift
//

import AdaAnimation
import AdaECS
import AdaUtils
import Foundation
import Math
import Testing

// Codable + KeyframeAnimatable used in JSON round-trip tests.
private struct TestValues: KeyframeAnimatable, Codable {
    var x: Float = 0
    var y: Float = 0
    var scale: Float = 1

    func apply(to entityId: Entity.ID, in world: World) {}
}

struct KeyframeClipJSONTests {

    @Test
    func roundTripVersion2_codableValue() throws {
        var schema = KeyframeClipSchema<TestValues>()
        schema.register("x", keyPath: \.x)
        schema.register("scale", keyPath: \.scale)

        let clip = KeyframeClip(
            name: "test",
            initialValues: TestValues(),
            duration: 1,
            repeatMode: .repeatCount(3)
        ) {
            KeyframeTrack(\.x, identifier: "x") {
                LinearKeyframe(Float(0), duration: 0.5)
                LinearKeyframe(Float(10), duration: 0.5)
            }
            KeyframeTrack(\.scale, identifier: "scale") {
                LinearKeyframe(Float(1), duration: 1)
            }
        }

        let data = try clip.encodeToJSONData(prettyPrinted: true)
        let decoded = try KeyframeClip<TestValues>(jsonData: data, schema: schema)

        #expect(decoded.name == "test")
        #expect(decoded.repeatMode == .repeatCount(3))
        #expect(decoded.tracks.count == 2)

        // Keyframes: t=0 → x=0, t=0.5 → x=10.  Midpoint is at t=0.25.
        let v = decoded.evaluate(at: 0.25)
        #expect(abs(Double(v.x) - 5) < 0.5)
    }

    @Test
    func repeatCountJSON_roundTrip() throws {
        let mode = KeyframeRepeatMode.repeatCount(4)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(mode)
        let decoded = try decoder.decode(KeyframeRepeatMode.self, from: data)
        #expect(decoded == .repeatCount(4))
    }

    @Test
    func backwardCompatStringRepeatMode() throws {
        let json = #"{"kind": "loop"}"#
        let decoder = JSONDecoder()
        // Old string form should also decode.
        let legacyData = Data("\"loop\"".utf8)
        let decoded = try decoder.decode(KeyframeRepeatMode.self, from: legacyData)
        #expect(decoded == .loop())
        _ = json // unused variable warning suppression
    }

    @Test
    func evaluateClip_interpolatesViaKeyPath() {
        // Keyframes: t=0 → x=0, t=0.5 → x=10. Duration=1.
        // Midpoint between t=0 and t=0.5 is at localTime=0.25 → x≈5.
        let clip = KeyframeClip(
            name: "move",
            initialValues: TestValues(),
            duration: 1,
            repeatMode: .once
        ) {
            KeyframeTrack(\.x, identifier: "x") {
                LinearKeyframe(Float(0), duration: 0.5)
                LinearKeyframe(Float(10), duration: 0.5)
            }
        }
        let mid = clip.evaluate(at: 0.25)
        #expect(abs(Double(mid.x) - 5) < 0.1)
        // At or past the second keyframe we clamp to x=10.
        let end = clip.evaluate(at: 0.5)
        #expect(abs(Double(end.x) - 10) < 0.01)
    }
}
