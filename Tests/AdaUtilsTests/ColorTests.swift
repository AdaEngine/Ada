@testable import AdaUtils
import Testing

@Suite("Color semantics")
struct ColorTests {
    @Test("clear is transparent black")
    func clearIsTransparentBlack() {
        #expect(Color.clear.red == 0)
        #expect(Color.clear.green == 0)
        #expect(Color.clear.blue == 0)
        #expect(Color.clear.alpha == 0)
    }
}
