import Foundation
import AdaUtils

/// Platform integration supplied by the embedding application for text links.
public struct OpenURLAction: Sendable {
    private let handler: @MainActor @Sendable (URL) -> Void
    public init(_ handler: @escaping @MainActor @Sendable (URL) -> Void) { self.handler = handler }
    @MainActor public func callAsFunction(_ url: URL) { handler(url) }
}

extension EnvironmentValues {
    @Entry public var openURL: OpenURLAction = OpenURLAction { _ in }
}
