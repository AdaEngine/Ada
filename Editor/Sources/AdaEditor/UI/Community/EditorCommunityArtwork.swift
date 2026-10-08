@_spi(AdaEngine) import AdaEngine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Decode on an actor outside the UI actor. PNG uses the same decoder on every platform.
private actor CommunityArtworkLoader {
    static let shared = CommunityArtworkLoader()

    func load(_ url: URL) async throws -> Image {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 24_000_000 else { throw EditorCommunityClient.CommunityError.invalidResponse }
        try Task.checkCancellation()
        return try Image.decode(from: data)
    }
}

struct EditorCommunityArtwork: View {
    @Environment(\.theme) private var theme
    @State private var image: Image?
    let url: URL?
    let height: Float

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    theme.editorColors.surfaceElevated
                    Text("\u{E80B}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 42))
                        .foregroundColor(theme.editorColors.purple)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .mask(RoundedRectangleShape(cornerRadius: 16))
        .task {
            guard let url else { return }
            do {
                let image = try await CommunityArtworkLoader.shared.load(url)
                try Task.checkCancellation()
                await MainActor.run { self.image = image }
            } catch { /* The placeholder also covers unavailable artwork. */ }
        }
    }
}
