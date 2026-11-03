import Math
import Observation

/// Only the completion overlay observes caret geometry. Moving the caret must
/// not invalidate the code view, its syntax spans, or the workspace around it.
@Observable
@MainActor
final class EditorCodeCaretState {
    var rect: Rect?
}
