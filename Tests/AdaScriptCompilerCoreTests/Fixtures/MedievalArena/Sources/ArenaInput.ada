import { ArenaGame, ArenaInputCommand } from "./ArenaState.ada";

@before(id: "arena.gameplay")
@system(scheduler: "update", id: "arena.input")
class ArenaInputSystem {
    @res var input: Input;
    @res var multiplayer: AdaScriptMultiplayerState;
    @res var network: Multiplayer;

    func update(context) {
        ArenaGame.moveX = input.getActionStrength("MoveRight") - input.getActionStrength("MoveLeft");
        ArenaGame.moveY = input.getActionStrength("MoveUp") - input.getActionStrength("MoveDown");
        if (input.isActionJustPressed("Attack")) {
            ArenaGame.attackSequence += 1;
        }

        if (multiplayer.role == "peer") {
            network.send(ArenaInputCommand(ArenaGame.moveX, ArenaGame.moveY, ArenaGame.attackSequence));
        }
    }
}
