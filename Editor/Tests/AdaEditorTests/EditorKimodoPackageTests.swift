import Crypto
import Foundation
import Testing

@testable import AdaEditor

@Suite
struct EditorKimodoPackageTests {
    #if os(Windows)
    @Test
    func requestEncodingRespectsTheWorkerByteLimit() throws {
        let id = UUID().uuidString
        let plain = EditorKimodoRunner.Request(jobID: id, prompt: String(repeating: "a", count: 4_096), duration: 4)
        let escaped = EditorKimodoRunner.Request(jobID: id, prompt: String(repeating: "\"", count: 4_096), duration: 4)
        #expect(try plain.encodedData().count <= 8_192)
        #expect(throws: EditorKimodoError.self) {
            _ = try escaped.encodedData()
        }
    }
    #endif

    @Test
    func publishedFormatRejectsDamagedPayloadsAndIncompleteZIPs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("extension.zip")
        let key = Curve25519.Signing.PrivateKey()
        var contents = Dictionary(uniqueKeysWithValues: EditorKimodoManifest.payload.map { ($0, Data($0.utf8)) })
        let manifest = try JSONSerialization.data(withJSONObject: [
            "extensionID": "org.adaengine.kimodo", "platform": "windows-x64", "version": "0.1.0", "minimumStudioVersion": "1.0.0",
            "protocolVersion": 1, "files": contents.mapValues(EditorKimodoManifest.digest),
        ])
        contents["manifest.json"] = manifest
        contents["manifest.sig"] = try key.signature(for: manifest)
        let keys = [key.publicKey.rawRepresentation]
        let zip = EditorPublicationZIP.encode(contents.map { .init(path: $0.key, data: $0.value) })
        try zip.write(to: archive)
        let verified = try EditorKimodoManifest.verify(EditorKimodoManifest.open(archive), keys: keys, studioVersion: "editor-v1.0.0-20261118")
        #expect(verified.version == "0.1.0")
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        #expect(throws: EditorKimodoError.self) {
            _ = try EditorKimodoManifest.verify(contents, keys: [otherKey], studioVersion: "1.0.0")
        }
        #expect(throws: EditorKimodoError.self) {
            _ = try EditorKimodoManifest.verify(contents, keys: keys, studioVersion: "0.9.0")
        }

        try zip.dropLast(6).write(to: archive)
        #expect(throws: EditorKimodoError.self) { _ = try EditorKimodoManifest.open(archive) }
        contents["worker.py"] = Data("changed".utf8)
        try EditorPublicationZIP.encode(contents.map { .init(path: $0.key, data: $0.value) }).write(to: archive)
        #expect(throws: EditorKimodoError.self) {
            _ = try EditorKimodoManifest.verify(EditorKimodoManifest.open(archive), keys: keys, studioVersion: "1.0.0")
        }
    }
}
