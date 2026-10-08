@scriptable(id: "game.hud")
class HUD {
    @export var title = "Hello";

    func ready(context) {
        title = "Game started";
    }
}
