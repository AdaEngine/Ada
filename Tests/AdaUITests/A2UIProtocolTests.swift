@testable import AdaA2UI
import AdaUIDescription
import Foundation
import Testing

struct A2UIProtocolTests {
    @Test func fragmentedUTF8AndCRLFKeepAllMessagesInOrder() throws {
        let source = Data("{\"name\":\"日本語\"}\r\n\n{\"name\":\"Ada\"}".utf8)
        var decoder = A2UIJSONLDecoder()
        var frames: [Data] = []
        for byte in source { frames += try decoder.append(Data([byte])).map { try $0.get() } }
        if let final = decoder.finish() { frames.append(final) }
        #expect(frames.count == 2)
        #expect(try JSONDecoder().decode(UIValue.self, from: frames[0]) == .object(["name": .string("日本語")]))
        #expect(try JSONDecoder().decode(UIValue.self, from: frames[1]) == .object(["name": .string("Ada")]))
        #expect(decoder.finish() == nil)
    }

    @Test func oversizedLineDoesNotDropNeighboringFrames() throws {
        var decoder = A2UIJSONLDecoder(maximumMessageBytes: 4)
        let frames = decoder.append(Data("{}\n123456789\n[]\n".utf8))
        #expect(frames.count == 3)
        #expect(try frames[0].get() == Data("{}".utf8))
        #expect(throws: A2UIValidationError.self) { try frames[1].get() }
        #expect(try frames[2].get() == Data("[]".utf8))
        #expect(decoder.finish() == nil)
    }

    @Test func CRLFEnvelopeAtTheExactByteLimitIsAccepted() throws {
        var decoder = A2UIJSONLDecoder(maximumMessageBytes: 2)
        let frames = decoder.append(Data("{}\r\n".utf8))
        #expect(frames.count == 1)
        #expect(try frames[0].get() == Data("{}".utf8))
    }

    @Test func pointersPreserveEscapedKeysDotsArraysAndDeletionSlots() throws {
        let pointer = try A2UIPointer("/profile/a~1b/~0.name")
        let model = try pointer.replacing(in: .object([:]), with: .string("Ada"))
        #expect(pointer.read(model) == .string("Ada"))
        #expect(model == .object(["profile": .object(["a/b": .object(["~.name": .string("Ada")])])]))
        let array: UIValue = .object(["items": .array([.string("A"), .string("B")])])
        #expect(try A2UIPointer("/items/1").replacing(in: array, with: nil) == .object(["items": .array([.string("A"), .null])]))
        #expect(try A2UIPointer("/items/2").replacing(in: array, with: .string("C")) == .object(["items": .array([.string("A"), .string("B"), .string("C")])]))
        #expect(throws: A2UIValidationError.self) { try A2UIPointer("/items/01").replacing(in: array, with: .null) }
        #expect(throws: A2UIValidationError.self) { try A2UIPointer("/items/3").replacing(in: array, with: .null) }
        #expect(throws: A2UIValidationError.self) { try A2UIPointer("/bad~2escape") }
        do {
            _ = try A2UIPointer("relative")
            Issue.record("Expected a relative path to be rejected.")
        } catch let failure as A2UIValidationError {
            #expect(failure.path == "/path")
        }
        #expect(try A2UIPointer("/").replacing(in: model, with: .string("Root")) == .string("Root"))
    }

    @Test func deeplyNestedPointersAreRejectedBeforeMutation() throws {
        #expect(throws: A2UIValidationError.self) { try A2UIPointer(String(repeating: "/key", count: 66)) }
    }

    @Test @MainActor func catalogCanBeLoadedWithoutAnyNetworkAccess() throws {
        let schema = try JSONDecoder().decode(UIValue.self, from: A2UIClient.catalogSchema())
        let commonTypes = try JSONDecoder().decode(UIValue.self, from: A2UIClient.commonTypesSchema())
        #expect(try commonTypes.objectFields()["$defs"] != nil)
        #expect(try schema.objectFields()["catalogId"] == .string(A2UIClient.catalogID))
        #expect(A2UIClient().capabilities == .object(["a2uiClientCapabilities": .object(["supportedCatalogIds": .array([.string(A2UIClient.catalogID)])])]))
    }
}
