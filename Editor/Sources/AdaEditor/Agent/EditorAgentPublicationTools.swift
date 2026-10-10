import Foundation
import MCP

enum EditorAgentPublicationTools {
    static func tools() -> [Tool] {
        let path: Value = .object(["type": "string", "description": "Project-relative image file path."])
        return [
            EditorMobileAgentTools.tool(
                "editor.community.submit",
                "Package this AdaScript app and submit to Cloud Community review. Requires sign-in and Pro. Updates the same app after approval. Use when the user requests publication.",
                [
                    "title": .object(["type": "string"]),
                    "description": .object(["type": "string"]),
                    "cover": path,
                    "screenshots": .object(["type": "array", "items": path, "maxItems": 5]),
                ],
                ["title", "description", "cover"],
                readOnly: false,
                openWorld: true
            ),
        ]
    }

    @MainActor
    static func submit(projectURL: URL, arguments: [String: Value]) async throws -> [String: Any] {
        guard let title = arguments["title"]?.stringValue, let description = arguments["description"]?.stringValue,
              let cover = arguments["cover"]?.stringValue else { throw EditorPublicationError("title, description and cover are required.") }
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        func image(_ path: String) throws -> URL {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw EditorPublicationError("Images must be project-relative files.")
            }
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()) else {
                throw EditorPublicationError("Choose a PNG, JPEG or WebP inside this project.")
            }
            return url
        }
        let screenshots: [URL]
        if let value = arguments["screenshots"] {
            guard let values = value.arrayValue, values.allSatisfy({ $0.stringValue != nil }), values.count <= 5 else {
                throw EditorPublicationError("screenshots must contain up to five project-relative paths.")
            }
            screenshots = try values.compactMap(\.stringValue).map(image)
        } else { screenshots = [] }
        let draft = EditorPublicationDraft(title: title, description: description, cover: try image(cover), screenshots: screenshots)
        #if canImport(AuthenticationServices) && canImport(StoreKit) && canImport(Security)
        let account = EditorCloudAccount.shared
        guard let owner = account.accountID else { throw EditorPublicationError("Sign in to Ada Cloud from Studio settings first.") }
        try await account.refreshPlan()
        guard account.pro, account.cloudServicesAvailable else { throw EditorPublicationError("Community publishing requires Cloud Pro and an available Cloud service.") }
        let release = try await EditorProjectPublisher.shared.submit(projectURL: root, draft: draft, owner: owner, server: account.server)
        return [
            "pageID": release["pageId"].string ?? "",
            "releaseID": release["id"].string ?? "",
            "status": release["status"].string ?? "",
            "number": release["number"].int ?? 1,
            "summary": "Submitted to Community review. The public app updates after approval.",
        ]
        #else
        throw EditorPublicationError("Cloud publishing is unavailable in this host.")
        #endif
    }
}
