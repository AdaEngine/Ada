/// Implement in a compiled Swift module to explicitly export its editor-facing UI API.
@MainActor
public protocol UIExportProvider {
    static var views: [UINativeViewDescriptor] { get }
    static var modifiers: [UINativeModifierDescriptor] { get }
}

extension UIExportProvider {
    public static var modifiers: [UINativeModifierDescriptor] { [] }
}

/// Retained by dynamically loaded preview modules for the lifetime of their factories.
@MainActor
public final class UIExportLibrary {
    public let views: [UINativeViewDescriptor]
    public let modifiers: [UINativeModifierDescriptor]

    public init<Provider: UIExportProvider>(_ provider: Provider.Type) {
        views = provider.views
        modifiers = provider.modifiers
    }
}
