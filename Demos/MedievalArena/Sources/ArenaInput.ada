import { ArenaGame } from "./ArenaState.ada";

@before(id: "arena.gameplay")
@system(scheduler: "update", id: "arena.input")
class ArenaInputSystem {
    @res var input: Input;
    @res var multiplayer: AdaScriptMultiplayerState;

    func update(context) {
        ArenaGame.moveX = input.getActionStrength("MoveRight") - input.getActionStrength("MoveLeft");
        ArenaGame.moveY = input.getActionStrength("MoveUp") - input.getActionStrength("MoveDown");
        if (input.isActionJustPressed("Attack")) {
            ArenaGame.attackSequence += 1;
        }

        if (multiplayer.role == "peer") {
            multiplayer.outgoingCommand = [ArenaGame.moveX, ArenaGame.moveY, ArenaGame.attackSequence];
            multiplayer.outgoingCommandSequence += 1;
        }
    }
}
