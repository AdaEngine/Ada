import Foundation
import Testing
@testable import AdaEditor

@Suite struct EditorAssetStoreTests {
    @Test func routesOnlyStoreAssetUUIDs() throws {
        let id = "fd12c886-1d2d-4e0c-a317-dff9d098ce2d"
        let valid = try #require(URL(string: "adaeditor://store/asset/" + id))
        #expect(EditorAssetStoreClient.assetID(from: valid) == id)
        for raw in [
            "adaeditor://store/asset/" + id + "?url=https://example.com",
            "adaeditor://store/asset/" + id + "#fragment",
            "adaeditor://store/asset/not-a-uuid",
            "adaeditor://store/asset/" + id + "/",
            "adaeditor://user@store/asset/" + id,
            "adaeditor://store:443/asset/" + id,
            "adaeditor://cloud/asset/" + id,
            "https://store/asset/" + id,
        ] {
            let url = try #require(URL(string: raw))
            #expect(EditorAssetStoreClient.assetID(from: url) == nil)
        }
    }
    @Test func rejectsInvalidSearchBeforeNetworking() async {
        await #expect(throws: EditorAssetStoreClient.StoreError.self) {
            try await EditorAssetStoreClient().search(query: "x", category: nil, sort: "unknown")
        }
        await #expect(throws: EditorAssetStoreClient.StoreError.self) {
            try await EditorAssetStoreClient().search(query: "", category: nil, limit: 101)
        }
    }
}
