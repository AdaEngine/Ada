import Foundation
import Observation

@MainActor
@Observable
final class EditorCommunityModel {
    let client: EditorCommunityClient
    var games: [EditorCommunityGame] = []
    var query = ""
    var popularFirst = false
    private(set) var loading = false
    private(set) var error: String?

    init(client: EditorCommunityClient) { self.client = client }

    var results: [EditorCommunityGame] {
        let filtered = games.filter { $0.matches(query) }
        return popularFirst ? filtered.sorted { $0.likes == $1.likes ? $0.id < $1.id : $0.likes > $1.likes } : filtered
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let games = try await client.games()
            try Task.checkCancellation()
            self.games = games
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
