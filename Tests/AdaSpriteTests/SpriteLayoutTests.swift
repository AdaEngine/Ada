import AdaRender
import AdaSprite
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Sprite layout coding")
struct SpriteLayoutTests {
    @Test("Old sprite payloads retain centered stretch layout")
    func legacyDecoding() throws {
        let encoded = try JSONEncoder().encode(Sprite(tintColor: .red, size: Size(width: 20, height: 10)))
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "anchor")
        payload.removeValue(forKey: "imageMode")
        let decoded = try JSONDecoder().decode(Sprite.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(decoded.anchor == .center)
        #expect(decoded.imageMode == .stretch)
        #expect(decoded.size == Size(width: 20, height: 10))
        #expect(decoded.tintColor == .red)
    }

    @Test("Every image mode survives sprite resource coding", arguments: [
        SpriteImageMode.stretch, .fit, .fill, .sliced(SpriteSliceBorder(top: 2, left: 3, bottom: 4, right: 5)),
        .tiled(tileX: true, tileY: false, scale: 2)
    ])
    func layoutRoundTrip(mode: SpriteImageMode) throws {
        let sprite = Sprite(size: Size(width: 120, height: 60), anchor: .bottomCenter, imageMode: mode)
        let decoded = try JSONDecoder().decode(Sprite.self, from: JSONEncoder().encode(sprite))
        #expect(decoded.anchor == .bottomCenter)
        #expect(decoded.imageMode == mode)
    }
}
