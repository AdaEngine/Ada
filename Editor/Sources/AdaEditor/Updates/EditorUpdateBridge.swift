import Foundation

// Shared wire names between the editor and its optional standalone updater framework.
// Values crossing the boundary are Foundation objects; neither module links to the other.
enum EditorUpdateBridge {
    static let stateChanged = Notification.Name("org.adaengine.editor.update.state")
    static let prepareRestart = Notification.Name("org.adaengine.editor.update.prepareRestart")
    static let frameworkName = "AdaEditorUpdater.framework"
}
