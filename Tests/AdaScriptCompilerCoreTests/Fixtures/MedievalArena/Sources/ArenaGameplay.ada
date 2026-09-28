import { ArenaGame, ArenaInputCommand, ArenaPlayer } from "./ArenaState.ada";

@after(id: "arena.input")
@before(id: "arena.presentation")
@system(scheduler: "update", id: "arena.gameplay")
class ArenaGameplaySystem {
    @res var multiplayer: AdaScriptMultiplayerState;
    @remote_commands(ArenaInputCommand) var commands;
    @query(ArenaPlayer) var players;

    func update(context) {
        if (multiplayer.role != "host") return;

        ensurePlayer(multiplayer.localPeerID, 0, context);
        var variant = 1;
        for (var peer in multiplayer.peerIDs) {
            ensurePlayer(peer, variant, context);
            variant += 1;
        }

        var inputs = [:];
        inputs[multiplayer.localPeerID] = [ArenaGame.moveX, ArenaGame.moveY, ArenaGame.attackSequence];
        for (var command in commands) {
            inputs[command.source] = [
                command.value.moveX,
                command.value.moveY,
                command.value.attackSequence
            ];
        }

        var attacks = [];
        for (var row in players) {
            var input = inputs[row.arenaPlayer.peer];
            if (input != null && stepPlayer(row, input, context.deltaTime)) {
                attacks.push([
                    row.arenaPlayer.peer,
                    row.arenaPlayer.x,
                    row.arenaPlayer.y,
                    row.arenaPlayer.facing
                ]);
            }
        }
        for (var attacker in attacks) {
            applyAttack(attacker);
        }
    }

    func ensurePlayer(peer, variant, context) {
        for (var row in players) {
            if (row.arenaPlayer.peer == peer) return;
        }
        var x = 0.0;
        var y = 0.0;
        if (variant == 0) x = -72.0;
        if (variant == 1) x = 72.0;
        if (variant == 2) y = 100.0;
        if (variant == 3) y = -100.0;
        if (variant == 4) { x = -180.0; y = 90.0; }
        if (variant >= 5) { x = 180.0; y = -90.0; }
        var facing = 3;
        if (variant != 0) facing = 2;
        context.world.spawn([ArenaPlayer(
            peer: peer,
            x: x,
            y: y,
            health: 3,
            facing: facing,
            attackSequence: 0,
            respawn: 0.0,
            variant: variant,
            consumedInput: 0
        )]);
    }

    func stepPlayer(row, input, deltaTime) {
        if (row.arenaPlayer.health <= 0) {
            row.arenaPlayer.respawn -= deltaTime;
            if (row.arenaPlayer.respawn <= 0.0) {
                row.arenaPlayer.health = 3;
                row.arenaPlayer.respawn = 0.0;
                if (row.arenaPlayer.variant == 0) { row.arenaPlayer.x = -72.0; row.arenaPlayer.y = 0.0; }
                if (row.arenaPlayer.variant == 1) { row.arenaPlayer.x = 72.0; row.arenaPlayer.y = 0.0; }
                if (row.arenaPlayer.variant == 2) { row.arenaPlayer.x = 0.0; row.arenaPlayer.y = 100.0; }
                if (row.arenaPlayer.variant == 3) { row.arenaPlayer.x = 0.0; row.arenaPlayer.y = -100.0; }
            }
            return false;
        }

        var moveX = ArenaGame.clamp(input[0], -1.0, 1.0);
        var moveY = ArenaGame.clamp(input[1], -1.0, 1.0);
        if (moveX != 0.0 && moveY != 0.0) {
            moveX *= 0.707106;
            moveY *= 0.707106;
        }
        row.arenaPlayer.x = ArenaGame.clamp(row.arenaPlayer.x + moveX * 175.0 * deltaTime, -410.0, 410.0);
        row.arenaPlayer.y = ArenaGame.clamp(row.arenaPlayer.y + moveY * 175.0 * deltaTime, -220.0, 220.0);
        if (moveX < -0.01) row.arenaPlayer.facing = 2;
        if (moveX > 0.01) row.arenaPlayer.facing = 3;
        if (moveY < -0.01) row.arenaPlayer.facing = 1;
        if (moveY > 0.01) row.arenaPlayer.facing = 0;

        var shouldAttack = input[2] > row.arenaPlayer.consumedInput;
        if (shouldAttack) {
            row.arenaPlayer.consumedInput = input[2];
            row.arenaPlayer.attackSequence += 1;
        }
        return shouldAttack;
    }

    func applyAttack(attacker) {
        for (var target in players) {
            if (target.arenaPlayer.peer != attacker[0] && target.arenaPlayer.health > 0) {
                    var dx = target.arenaPlayer.x - attacker[1];
                    var dy = target.arenaPlayer.y - attacker[2];
                    var inReach = dx * dx + dy * dy <= 3844.0;
                    var inFront = false;
                    if (attacker[3] == 0 && dy > 10.0) inFront = true;
                    if (attacker[3] == 1 && dy < -10.0) inFront = true;
                    if (attacker[3] == 2 && dx < -10.0) inFront = true;
                    if (attacker[3] == 3 && dx > 10.0) inFront = true;
                    if (inReach && inFront) {
                        target.arenaPlayer.health -= 1;
                        if (target.arenaPlayer.health <= 0) {
                            target.arenaPlayer.health = 0;
                            target.arenaPlayer.respawn = 2.0;
                        }
                    }
            }
        }
    }
}
