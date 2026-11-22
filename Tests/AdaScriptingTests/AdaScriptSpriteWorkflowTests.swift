import AdaAssets
@testable import AdaScripting
import Testing

@Suite("AdaScript sprite workflow: palettes, layers and frames", .serialized)
@MainActor
struct AdaScriptSpriteWorkflowTests {
    @Test("A bundled palette preset loads exact PICO-8 colors")
    func palettePresetLoadsBundledColors() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(4, 4);
                sprite.palettePreset("pico-8");
                sprite.pixel(0, 0, 1);
                sprite.pixel(1, 0, 2);
                sprite.pixel(2, 0, 16);
            }
            """
        )
        #expect(result.canvas.palette[1] == PixelColor(red: 0x00, green: 0x00, blue: 0x00))
        #expect(result.canvas.palette[2] == PixelColor(red: 0x1D, green: 0x2B, blue: 0x53))
        #expect(result.canvas.palette[16] == PixelColor(red: 0xFF, green: 0xCC, blue: 0xAA))
        #expect(result.canvas.palette[17] == PixelColor(red: 255, green: 0, blue: 255))
    }

    @Test("A palette preset may be selected before the canvas size")
    func palettePresetBeforeSize() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.palettePreset("gameboy");
                sprite.size(2, 2);
                sprite.fill(4);
            }
            """
        )
        #expect(result.canvas.palette[4] == PixelColor(red: 0x9B, green: 0xBC, blue: 0x0F))
    }

    @Test("A preset followed by palette() overrides single entries")
    func palettePresetThenOverride() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(2, 2);
                sprite.palettePreset("pico-8");
                sprite.palette(1, 1, 2, 3);
                sprite.fill(1);
            }
            """
        )
        #expect(result.canvas.palette[1] == PixelColor(red: 1, green: 2, blue: 3))
        #expect(result.canvas.palette[2] == PixelColor(red: 0x1D, green: 0x2B, blue: 0x53))
    }

    @Test("User palettes resolve through the user: prefix")
    func userPalettePreset() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(2, 2);
                sprite.palettePreset("user:brand");
                sprite.fill(2);
            }
            """,
            userPalettes: ["brand": [PixelColor(red: 10, green: 20, blue: 30), PixelColor(red: 40, green: 50, blue: 60)]]
        )
        #expect(result.canvas.palette[1] == PixelColor(red: 10, green: 20, blue: 30))
        #expect(result.canvas.palette[2] == PixelColor(red: 40, green: 50, blue: 60))
    }

    @Test("Unknown palette presets are rejected")
    func rejectsUnknownPresets() {
        let scripts = [
            "func build(sprite) { sprite.size(2, 2); sprite.palettePreset(\"no-such-palette\"); sprite.fill(1); }",
            "func build(sprite) { sprite.size(2, 2); sprite.palettePreset(\"user:missing\"); sprite.fill(1); }",
            "func build(sprite) { sprite.size(2, 2); sprite.palettePreset(42); sprite.fill(1); }",
        ]
        for script in scripts {
            #expect(throws: (any Error).self, "\(script)") { try AdaScriptSpriteGenerator.generate(source: script) }
        }
    }

    @Test("Layers flatten in creation order and report their names")
    func layersFlattenInOrder() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(4, 4);
                sprite.palette(1, 200, 0, 0);
                sprite.palette(2, 0, 0, 200);
                sprite.beginLayer("body");
                sprite.fill(1);
                sprite.endLayer();
                sprite.beginLayer("fx");
                sprite.pixel(0, 0, 2);
                sprite.endLayer();
            }
            """
        )
        #expect(result.layers == ["body", "fx"])
        #expect(result.canvas.color(x: 0, y: 0) == 2)
        #expect(result.canvas.color(x: 3, y: 3) == 1)
    }

    @Test("Re-entering a layer clears only that layer")
    func layerRedrawClearsOnlyItself() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(4, 4);
                sprite.palette(1, 200, 0, 0);
                sprite.palette(2, 0, 0, 200);
                sprite.beginLayer("body");
                sprite.fill(1);
                sprite.endLayer();
                sprite.beginLayer("fx");
                sprite.fill(2);
                sprite.endLayer();
                sprite.beginLayer("fx");
                sprite.pixel(3, 3, 2);
                sprite.endLayer();
            }
            """
        )
        #expect(result.layers == ["body", "fx"])
        #expect(result.canvas.color(x: 0, y: 0) == 1)
        #expect(result.canvas.color(x: 3, y: 3) == 2)
    }

    @Test("Flat drawing without layers keeps painting on the base canvas")
    func baseCanvasSurvivesLayers() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(4, 4);
                sprite.palette(1, 200, 0, 0);
                sprite.palette(2, 0, 0, 200);
                sprite.fill(1);
                sprite.beginLayer("fx");
                sprite.pixel(0, 0, 2);
                sprite.endLayer();
                sprite.pixel(1, 1, 2);
            }
            """
        )
        #expect(result.canvas.color(x: 0, y: 0) == 2)
        #expect(result.canvas.color(x: 1, y: 1) == 2)
        #expect(result.canvas.color(x: 3, y: 3) == 1)
    }

    @Test("A frame count turns the canvas into a horizontal strip")
    func framesBuildAStrip() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(8, 8, 4);
                sprite.palette(1, 255, 255, 255);
                sprite.frame(2);
                sprite.pixel(0, 0, 1);
                sprite.frameDuration(2, 80);
                sprite.tag("walk", 0, 3);
            }
            """
        )
        #expect(result.frameWidth == 8 && result.frameCount == 4)
        #expect(result.canvas.width == 32 && result.canvas.height == 8)
        #expect(result.canvas.color(x: 16, y: 0) == 1)
        #expect(result.canvas.color(x: 0, y: 0) == 0)
        #expect(result.canvas.color(x: 24, y: 0) == 0)
        #expect(result.frameDurations == [100, 100, 80, 100])
        #expect(result.tags == [AdaScriptSpriteTag(name: "walk", from: 0, to: 3)])
    }

    @Test("Mirror applies to the selected frame cell only")
    func mirrorIsPerFrame() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(8, 8, 2);
                sprite.palette(1, 255, 255, 255);
                sprite.frame(1);
                sprite.pixel(0, 0, 1);
                sprite.mirror();
            }
            """
        )
        #expect(result.canvas.color(x: 8, y: 0) == 1)
        #expect(result.canvas.color(x: 15, y: 0) == 1)
        #expect(result.canvas.color(x: 0, y: 0) == 0)
        #expect(result.canvas.color(x: 7, y: 0) == 0)
    }

    @Test("Layers and frames compose: every layer spans the whole strip")
    func layersAndFramesCompose() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: """
            func build(sprite) {
                sprite.size(4, 4, 2);
                sprite.palette(1, 200, 0, 0);
                sprite.palette(2, 0, 0, 200);
                sprite.beginLayer("body");
                sprite.fill(1);
                sprite.frame(1);
                sprite.fill(1);
                sprite.endLayer();
                sprite.beginLayer("fx");
                sprite.frame(1);
                sprite.pixel(0, 0, 2);
                sprite.endLayer();
            }
            """
        )
        #expect(result.canvas.width == 8)
        #expect(result.canvas.color(x: 0, y: 0) == 1)
        #expect(result.canvas.color(x: 4, y: 0) == 2)
        #expect(result.canvas.color(x: 5, y: 1) == 1)
    }

    @Test("Single-frame sprites keep frame metadata trivial")
    func flatSpriteMetadata() throws {
        let result = try AdaScriptSpriteGenerator.generate(
            source: "func build(sprite) { sprite.size(4, 4); sprite.fill(1); }"
        )
        #expect(result.frameCount == 1 && result.frameWidth == 4)
        #expect(result.frameDurations == [100])
        #expect(result.tags.isEmpty && result.layers.isEmpty)
    }

    @Test("Rejects invalid layer and frame scripts")
    func rejectsInvalidWorkflowScripts() {
        let scripts = [
            "func build(sprite) { sprite.size(8, 8, 0); sprite.fill(1); }",
            "func build(sprite) { sprite.size(300, 8, 2); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 65); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.frame(2); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.frame(-1); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.frameDuration(2, 100); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.frameDuration(0, 0); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.tag(\"walk\", 3, 1); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8, 2); sprite.tag(\"walk\", 0, 2); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8); sprite.frame(0); sprite.fill(1); }",
            "func build(sprite) { sprite.beginLayer(\"fx\"); sprite.size(8, 8); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8); sprite.beginLayer(\"\"); sprite.fill(1); }",
            "func build(sprite) { sprite.size(8, 8); sprite.endLayer(); sprite.fill(1); }",
        ]
        for script in scripts {
            #expect(throws: (any Error).self, "\(script)") { try AdaScriptSpriteGenerator.generate(source: script) }
        }
    }
}
