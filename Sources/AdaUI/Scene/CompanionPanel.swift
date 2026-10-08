import AdaECS

/// A source-backed UI shown in the secondary region of an AdaptiveSceneView.
/// Attach scripts to this entity and use `source.scriptBindings` for queued writes and detached snapshots.
@Component
public struct CompanionPanel: Sendable, Codable {
    public let ui: UIComponent

    public init(source: UIComponentSource) {
        ui = UIComponent(source: source)
    }

    private enum CodingKeys: String, CodingKey { case source }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(UIComponentSource.self, forKey: .source))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ui.source, forKey: .source)
    }
}
