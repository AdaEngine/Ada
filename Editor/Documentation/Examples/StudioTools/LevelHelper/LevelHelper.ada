@tool(
    id: "studio.level-helper",
    name: "Level Helper",
    version: "1.0.0",
    api: 1,
    platforms: ["macos"],
    permissions: ["editor.documents.read", "editor.documents.write"]
)
class LevelHelper {
    @export var count = 3.0;
    @export var status = "Open a scene, choose a count, then Generate.";

    func activate(editor) {
        editor.addPanel(id: "level-helper", title: "Level Helper", location: "right", ui: "LevelHelper.ui");
    }

    func generate(editor) {
        if (editor.scenePath == "") {
            status = "Open a scene first.";
            return;
        }
        var total = Math.clamp(count, 1.0, 32.0);
        var i = 0;
        while (i < total) {
            editor.createEntity(name: "Generated " + (i + 1), x: i * 48.0, y: 0.0);
            i += 1;
        }
        status = "Generated " + total + " entities. Undo reverses the whole batch.";
    }

    func deactivate() {}
}
