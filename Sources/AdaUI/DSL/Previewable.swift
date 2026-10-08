//
//  Previewable.swift
//  AdaEngine
//

/// A type that can be instantiated by AdaEditor previews.
///
/// Use ``Previewable(title:)`` on a `View` type to make it available
/// to AdaEditor preview tooling.
@MainActor
public protocol AdaPreviewable: View {
    static var adaPreviewTitle: String? { get }
    static func makeAdaPreview() -> AnyView
}

/// Marks an AdaUI `View` type as available for AdaEditor previews.
///
/// The annotated type must be constructible from its declaring module with `Self()`.
@attached(peer, names: prefixed(ada_editor_preview_make_))
@attached(extension, names: arbitrary, conformances: AdaPreviewable)
public macro Previewable(title: String? = nil) = #externalMacro(module: "AdaEngineMacros", type: "PreviewableMacro")
