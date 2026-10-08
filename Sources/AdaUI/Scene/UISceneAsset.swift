import AdaAssets
import AdaRender
import AdaUIDescription
import AdaUtils
import Foundation

/// A reusable, VM-independent UI resource.
public struct UISceneAsset: Asset {
    public var document: UISceneDocument
    public var assetMetaInfo: AssetMetaInfo?

    public init(document: UISceneDocument) throws {
        try document.validate()
        self.document = document
    }
    public init(from assetDecoder: any AssetDecoder) throws {
        document = try UISceneDocument.decode(String(bytes: assetDecoder.assetData, encoding: .utf8) ?? "")
    }
    public func encodeContents(with assetEncoder: any AssetEncoder) throws { try assetEncoder.encode(document) }
    public static func extensions() -> [String] { ["ui"] }
}

/// Resolves relative resources and caches parsed documents for one runtime session.
@MainActor
public final class UISceneResources {
    public let rootURL: URL
    private var images: [URL: Image] = [:]
    private var documents: [URL: UISceneDocument] = [:]
    public private(set) var dependencies: Set<URL> = []

    public init(rootURL: URL) { self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL }

    public func resolve(_ path: String, relativeTo source: URL? = nil) throws -> URL {
        let url: URL
        if path.hasPrefix("@res://") {
            url = rootURL.appendingPathComponent(String(path.dropFirst(7)))
        } else if path.hasPrefix("res://") {
            url = rootURL.appendingPathComponent(String(path.dropFirst(6)))
        } else if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = (source?.deletingLastPathComponent() ?? rootURL).appendingPathComponent(path)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootURL.path + "/") else {
            throw UIDiagnostic("UI resource is outside resource root: \(path)")
        }
        return resolved
    }

    public func image(_ path: String, relativeTo source: URL? = nil) throws -> Image {
        let url = try resolve(path, relativeTo: source)
        dependencies.insert(url)
        if let image = images[url] {
            return image
        }
        let image = try Image(contentsOf: url)
        images[url] = image
        return image
    }

    public func load(_ url: URL) throws -> UISceneDocument {
        dependencies.insert(url)
        if let document = documents[url] {
            return document
        }
        let document = try UISceneDocument.decode(String(contentsOf: url, encoding: .utf8))
        documents[url] = document
        return document
    }

    /// Publishes validated content from an unsaved editor document.
    public func publish(_ document: UISceneDocument, at url: URL) throws {
        try document.validate()
        documents[url.resolvingSymlinksInPath().standardizedFileURL] = document
    }

    public func invalidate(_ url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        documents.removeValue(forKey: url)
        images.removeValue(forKey: url)
    }
}

/// A file watcher or authoring tool publishes changes through the normal AdaUI event manager.
public struct UISceneResourceChanged: Event {
    public let url: URL
    public let document: UISceneDocument?
    public init(url: URL, document: UISceneDocument? = nil) {
        self.url = url
        self.document = document
    }
}
