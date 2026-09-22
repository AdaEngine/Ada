import { ArenaGame, ArenaInputCommand } from "./ArenaState.ada";

@after(id: "arena.input")
@before(id: "arena.presentation")
@system(scheduler: "update", id: "arena.gameplay")
class ArenaGameplaySystem {
    @res var multiplayer: AdaScriptMultiplayerState;
    @remote_commands(ArenaInputCommand) var commands;

    func update(context) {
        if (multiplayer.role != "host") return;

        ArenaGame.ensurePlayer(multiplayer.localPeerID, 0);
        var variant = 1;
        for (var peer in multiplayer.peerIDs) {
            ArenaGame.ensurePlayer(peer, variant);
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

        stepPlayer(multiplayer.localPeerID, inputs[multiplayer.localPeerID], context.deltaTime);
        for (var peer in multiplayer.peerIDs) {
            var peerInput = inputs[peer];
            if (peerInput != null) stepPlayer(peer, peerInput, context.deltaTime);
        }

        ArenaGame.snapshotClock += context.deltaTime;
        if (ArenaGame.snapshotClock >= 0.05) {
            ArenaGame.snapshotClock = 0.0;
            publishSnapshot();
        }
    }

    func stepPlayer(peer, input, deltaTime) {
        var player = ArenaGame.players[peer];
        if (player == null) return;

        if (player[2] <= 0) {
            player[6] -= deltaTime;
            if (player[6] <= 0.0) {
                player[2] = 3;
                player[6] = 0.0;
                if (player[7] == 0) { player[0] = -72.0; player[1] = 0.0; }
                if (player[7] == 1) { player[0] = 72.0; player[1] = 0.0; }
                if (player[7] == 2) { player[0] = 0.0; player[1] = 100.0; }
                if (player[7] == 3) { player[0] = 0.0; player[1] = -100.0; }
            }
            ArenaGame.players[peer] = player;
            return;
        }

        var moveX = ArenaGame.clamp(input[0], -1.0, 1.0);
        var moveY = ArenaGame.clamp(input[1], -1.0, 1.0);
        if (moveX != 0.0 && moveY != 0.0) {
            moveX *= 0.707106;
            moveY *= 0.707106;
        }
        player[0] = ArenaGame.clamp(player[0] + moveX * 175.0 * deltaTime, -410.0, 410.0);
        player[1] = ArenaGame.clamp(player[1] + moveY * 175.0 * deltaTime, -220.0, 220.0);
        if (moveX < -0.01) player[3] = 2;
        if (moveX > 0.01) player[3] = 3;
        if (moveY < -0.01) player[3] = 1;
        if (moveY > 0.01) player[3] = 0;

        var shouldAttack = input[2] > player[5];
        if (shouldAttack) {
            player[5] = input[2];
            player[4] += 1;
        }
        ArenaGame.players[peer] = player;
        if (shouldAttack) applyAttack(peer);
    }

    func applyAttack(attackerPeer) {
        var attacker = ArenaGame.players[attackerPeer];
        for (var targetPeer in ArenaGame.players.keys()) {
            if (targetPeer != attackerPeer) {
                var target = ArenaGame.players[targetPeer];
                if (target[2] > 0) {
                    var dx = target[0] - attacker[0];
                    var dy = target[1] - attacker[1];
                    var inReach = dx * dx + dy * dy <= 3844.0;
                    var inFront = false;
                    if (attacker[3] == 0 && dy > 10.0) inFront = true;
                    if (attacker[3] == 1 && dy < -10.0) inFront = true;
                    if (attacker[3] == 2 && dx < -10.0) inFront = true;
                    if (attacker[3] == 3 && dx > 10.0) inFront = true;
                    if (inReach && inFront) {
                        target[2] -= 1;
                        if (target[2] <= 0) {
                            target[2] = 0;
                            target[6] = 2.0;
                        }
                        ArenaGame.players[targetPeer] = target;
                    }
                }
            }
        }
    }

    func publishSnapshot() {
        var snapshot = [];
        for (var peer in ArenaGame.players.keys()) {
            var player = ArenaGame.players[peer];
            snapshot.push(peer);
            snapshot.push(player[0]);
            snapshot.push(player[1]);
            snapshot.push(player[2]);
            snapshot.push(player[3]);
            snapshot.push(player[4]);
            snapshot.push(player[6]);
            snapshot.push(player[7]);
        }
        multiplayer.publishedSnapshot = snapshot;
        multiplayer.publishedSnapshotSequence += 1;
    }
}
