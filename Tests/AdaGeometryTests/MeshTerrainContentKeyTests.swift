import AdaGeometry
import Foundation
import Testing

@Suite struct MeshTerrainContentKeyTests {
    @Test func standardDigestVectors() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(MeshTerrainContentKey.digest(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(MeshTerrainContentKey.digest(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(MeshTerrainContentKey.digest(Data(repeating: 97, count: 1_000))) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
