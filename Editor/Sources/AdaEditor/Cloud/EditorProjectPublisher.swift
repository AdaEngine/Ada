import Foundation

struct EditorPublicationDraft: Codable, Sendable {
    var title: String
    var description = ""
    var cover: URL?
    var screenshots: [URL] = []

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 100 else {
            throw EditorPublicationError("Enter a title up to 100 UTF-8 bytes.")
        }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.utf8.count <= 5000 else {
            throw EditorPublicationError("Enter a description up to 5000 UTF-8 bytes.")
        }
        guard cover != nil, screenshots.count <= 5 else { throw EditorPublicationError("Choose a cover and up to five screenshots.") }
    }

    static func load(at root: URL, title: String) -> Self {
        (try? Data(contentsOf: root.appendingPathComponent(".ada/publication-draft.json")))
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init(title: title)
    }

    func save(at root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent(".ada/publication-draft.json"), options: .atomic)
    }
}

/// UI and agent publishing share project identity, retry state and Cloud moderation submission.
@MainActor
final class EditorProjectPublisher {
    static let shared = EditorProjectPublisher(
        checkSession: { owner, server in
            guard EditorCloudAccount.shared.accountID == owner, EditorCloudAccount.shared.server == server else { throw EditorAIError.sessionChanged }
        },
        request: { path, method, body in try await EditorCloudAccount.shared.request(path, method: method, body: body) },
        uploadImage: { data in try await EditorCloudAccount.shared.uploadPublicationImage(data) },
        submitArchive: { zip, page in try await EditorCloudAccount.shared.publish(zip: zip, mode: "ugc", pageID: page) }
    )

    private let request: @MainActor (String, String, EditorCloudValue?) async throws -> EditorCloudValue
    private let uploadImage: @MainActor (Data) async throws -> EditorCloudValue
    private let submitArchive: @MainActor (URL, String) async throws -> EditorCloudValue
    private let checkSession: @MainActor (String, String) throws -> Void
    private let defaults: UserDefaults
    private var submitting = false

    init(
        defaults: UserDefaults = .standard,
        checkSession: @escaping @MainActor (String, String) throws -> Void = { _, _ in },
        request: @escaping @MainActor (String, String, EditorCloudValue?) async throws -> EditorCloudValue,
        uploadImage: @escaping @MainActor (Data) async throws -> EditorCloudValue,
        submitArchive: @escaping @MainActor (URL, String) async throws -> EditorCloudValue
    ) {
        self.defaults = defaults
        self.checkSession = checkSession
        self.request = request
        self.uploadImage = uploadImage
        self.submitArchive = submitArchive
    }

    func submit(projectURL: URL, draft: EditorPublicationDraft, owner: String, server: String) async throws -> EditorCloudValue {
        guard !submitting else { throw EditorPublicationError("A publication is already being submitted. Wait for it to finish.") }
        submitting = true
        defer { submitting = false }
        try checkSession(owner, server)
        try draft.validate()
        let project = try ProjectSystem.loadProject(at: projectURL)
        // Package and validate every local input before creating anything in Cloud.
        let archive = try await EditorCommunityProjectPackager.archive(projectURL: projectURL)
        try checkSession(owner, server)
        let imageURLs = [draft.cover].compactMap { $0 } + draft.screenshots
        let images = try imageURLs.map { url -> Data in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 5_000_000 else { throw EditorPublicationError("Each image must be at most 5 MB.") }
            return try Data(contentsOf: url)
        }
        let key = "AdaEditor.cloud.projectPublication." + EditorCommunityPackageManifest.digest(Data((server + "|" + owner + "|" + project.project.id).utf8))
        var state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(EditorCloudValue.self, from: $0) } ?? [:]
        func save() throws { defaults.set(try JSONEncoder().encode(state), forKey: key) }
        var mediaIDs: [EditorCloudValue] = []
        for data in images {
            try Task.checkCancellation()
            let digest = EditorCommunityPackageManifest.digest(data)
            if let id = state["media"][digest].string { mediaIDs.append(.string(id)); continue }
            try checkSession(owner, server)
            let media = try await uploadImage(data)
            try checkSession(owner, server)
            guard let id = media["id"].string, UUID(uuidString: id) != nil else { throw EditorPublicationError("Invalid image upload response.") }
            state["media"][digest] = .string(id)
            try save()
            mediaIDs.append(.string(id))
        }
        let metadata: EditorCloudValue = [
            "title": .string(draft.title),
            "description": .string(draft.description),
            "cover": mediaIDs[0],
            "screenshots": .array(Array(mediaIDs.dropFirst())),
            "tags": [],
        ]
        try checkSession(owner, server)
        let pageID: String
        if let existing = state["pageID"].string {
            pageID = existing
            _ = try await request("/pages/" + existing, "PATCH", metadata)
        } else {
            let page = try await request("/pages", "POST", metadata)
            try checkSession(owner, server)
            guard let id = page["id"].string, UUID(uuidString: id) != nil else { throw EditorPublicationError("Invalid game page response.") }
            pageID = id
            state["pageID"] = .string(id)
            try save()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fingerprint = EditorCommunityPackageManifest.digest(archive) + EditorCommunityPackageManifest.digest(try encoder.encode(metadata))
        if state["fingerprint"].string == fingerprint, let previousID = state["release"]["id"].string {
            let releases = try await request("/game-releases?pageId=" + pageID, "GET", nil)
            try checkSession(owner, server)
            if let current = releases.array.first(where: { $0["id"].string == previousID }),
               ["pending", "approved"].contains(current["status"].string ?? "") {
                state["release"] = current
                try save()
                return current
            }
        }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("community-" + pageID + ".zip")
        try archive.write(to: zip, options: .atomic)
        defer { try? FileManager.default.removeItem(at: zip) }
        try checkSession(owner, server)
        let release = try await submitArchive(zip, pageID)
        try checkSession(owner, server)
        guard let id = release["id"].string, UUID(uuidString: id) != nil,
              ["pending", "approved"].contains(release["status"].string ?? "") else {
            throw EditorPublicationError("The server did not accept this release for review.")
        }
        state["fingerprint"] = .string(fingerprint)
        state["release"] = release
        try save()
        try draft.save(at: projectURL)
        return release
    }
}
