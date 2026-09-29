import AdaUtils

private struct TextInsertionPointColorKey: ThemeKey {
    static let defaultValue: Color? = nil
}

extension Theme {
    /// The insertion cursor color for `TextField` and `TextEditor`.
    /// When `nil`, text inputs use the environment's accent color.
    public var textInsertionPointColor: Color? {
        get { self[TextInsertionPointColorKey.self] }
        set { self[TextInsertionPointColorKey.self] = newValue }
    }
}
