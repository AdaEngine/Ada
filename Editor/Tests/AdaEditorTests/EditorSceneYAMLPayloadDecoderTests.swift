import AdaStudioCore
import Foundation
import Testing
import Yams

@testable import AdaEditor

@Suite("Scene YAML payload decoding")
struct EditorSceneYAMLPayloadDecoderTests {
    /// Covers scalar resolution, nesting, anchors/aliases, merge keys and string styles.
    private static let scene = #"""
    format: ada.scene
    schemaVersion: 1
    engineVersion: 1.0.0
    scene:
      id: 123
      name: "СЕВЕР \xB7 north"
    entities:
    - id: root
      name: Root
      enabled: true
      components:
        AdaTransform.Transform:
          position: [0, -1.5, 2e-3]
          rotation: [0, 0, 0, 1]
          scale: &unit [1, 1, 1]
    - id: mesh
      parent: root
      name: 'Квадрат'
      enabled: yes
      components:
        AdaTransform.Transform:
          position: [1, 2, 3]
          scale: *unit
        AdaPhysics.PhysicsBody3DComponent:
          mode:
            static: {}
          shapes:
          - fixture:
              triangleMesh:
                _0:
                  vertices:
                  - x: 80
                    z: 75
                    y: -4.80000004172325e-1
                  - {x: .inf, y: -.Inf, z: 0x1F}
                  indices: [0, 1, 2]
        Custom.Values:
          nothing: ~
          empty:
          nullWord: null
          truth: true
          falsehood: False
          hex: 0x1F
          octal: 0o17
          huge: 18446744073709551615
          negative: -42
          float: 3.25
          exponent: 5e-4
          quotedNumber: "123"
          singleQuoted: 'true'
          date: 2026-11-08
          version: 1.0.0
          text: plain words
          multiline: |
            first
            second
          folded: >
            folded
            text
          base: &base {a: 1, b: two}
          merged:
            <<: *base
            b: three
          other: &other {b: four, c: 5, d: [1]}
          multiMerged:
            <<: [*base, *other]
            c: six
          nested: [[1, [2, {k: v}]], {list: [a, b]}]
    editor:
      selectedEntity: mesh
      expandedEntities: [root]
      viewport:
        position: [0, 0]
        zoom: 1.5
    """#

    @Test("Direct payload conversion matches the YAMLDecoder path")
    func matchesYAMLDecoder() throws {
        let fast = try EditorSceneYAMLPayloadDecoder.decode(Self.scene)
        let reference = try YAMLDecoder(encoding: .utf8).decode(EditorSceneModel.self, from: Self.scene)

        #expect(fast == reference)
        #expect(try EditorSceneModel.decode(from: Self.scene) == reference)
        let values = try #require(fast.entities.last?.components["Custom.Values"])
        #expect(values["huge"] == .uint(UInt64.max))
        #expect(values["quotedNumber"] == reference.entities.last?.components["Custom.Values"]?["quotedNumber"])
        #expect(fast.scene.id == "123")
        #expect(values["merged"] == .object(["a": .int(1), "b": .string("three")]))
        #expect(values["multiMerged"]?["c"] == .string("six"))
    }

    @Test("Invalid documents fail the same way through the fallback path")
    func invalidDocumentsStillFail() throws {
        // Yams rejects duplicate keys while parsing, so neither path can disagree about them.
        let duplicateComponents = Self.scene.replacingOccurrences(
            of: "  enabled: true\n  components:\n",
            with: "  enabled: true\n  components: {}\n  components:\n"
        )
        #expect(throws: (any Error).self) { try EditorSceneYAMLPayloadDecoder.decode(duplicateComponents) }
        #expect(throws: (any Error).self) { try EditorSceneModel.decode(from: duplicateComponents) }

        let missingComponents = "format: ada.scene\nschemaVersion: 1\nscene: {id: s, name: S}\nentities:\n- {id: a, name: A, enabled: true}\n"
        #expect(throws: EditorSceneYAMLPayloadDecoder.Unsupported.self) { try EditorSceneYAMLPayloadDecoder.decode(missingComponents) }

        // Yams hides these marker keys from keyed containers; the fallback path keeps that behavior.
        let markerKey = Self.scene.replacingOccurrences(of: "      truth: true\n", with: "      truth: true\n      yamlAnchor: hidden\n")
        #expect(markerKey != Self.scene)
        #expect(throws: EditorSceneYAMLPayloadDecoder.Unsupported.self) { try EditorSceneYAMLPayloadDecoder.decode(markerKey) }
        #expect(try EditorSceneModel.decode(from: markerKey) == YAMLDecoder(encoding: .utf8).decode(EditorSceneModel.self, from: markerKey))
        #expect(throws: (any Error).self) { try EditorSceneModel.decode(from: missingComponents) }
    }

    @Test("Profile decoding a real YAML scene", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_PERF_SCENE"] != nil))
    func realSceneDecode() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_PERF_SCENE"])
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let clock = ContinuousClock()
        let fastStart = clock.now
        let fast = try EditorSceneYAMLPayloadDecoder.decode(content)
        let fastDuration = fastStart.duration(to: clock.now)
        let parseStart = clock.now
        let parser = try Parser(yaml: content, resolver: Resolver.basic.appending(.merge), encoding: .utf8)
        _ = try withExtendedLifetime(parser) { try parser.singleRoot() }
        let parseDuration = parseStart.duration(to: clock.now)
        var line = "Scene decode benchmark: bytes=\(content.utf8.count), entities=\(fast.entities.count), payload path=\(fastDuration), of which Yams parse≈\(parseDuration)"
        if ProcessInfo.processInfo.environment["ADAEDITOR_PERF_SCENE_COMPARE"] != nil {
            let referenceStart = clock.now
            let reference = try YAMLDecoder(encoding: .utf8).decode(EditorSceneModel.self, from: content)
            line += ", YAMLDecoder path=\(referenceStart.duration(to: clock.now))"
            #expect(fast == reference)
        }
        print(line)
    }
}
