import { ArenaGame } from "./ArenaState.ada";

@after(id: "arena.gameplay")
@system(scheduler: "update", id: "arena.presentation")
class ArenaPresentationSystem {
    @res var multiplayer: AdaScriptMultiplayerState;
    @query(Transform, Sprite) var visuals;

    func update(context) {
        var snapshot = multiplayer.receivedSnapshot;
        if (multiplayer.role == "host") snapshot = multiplayer.publishedSnapshot;

        var index = 0;
        while (index + 7 < snapshot.count) {
            var peer = snapshot[index];
            var state = [
                snapshot[index + 1], snapshot[index + 2], snapshot[index + 3],
                snapshot[index + 4], snapshot[index + 5], snapshot[index + 6],
                snapshot[index + 7]
            ];
            ensureVisuals(peer, state, context);
            presentAttack(peer, state, context);
            ArenaGame.players[peer] = [
                state[0], state[1], state[2], state[3], state[4], 0, state[5], state[6]
            ];
            index += 8;
        }

        for (var row in visuals) {
            updateVisual(row, context);
        }
    }

    func ensureVisuals(peer, state, context) {
        if (ArenaGame.playerEntities[peer] == null) {
            ArenaGame.playerEntities[peer] = spawnVisual(
                Vector3(state[0], state[1], 4.0),
                context
            );
        }
        if (ArenaGame.heartEntities[peer] == null) {
            ArenaGame.heartEntities[peer] = [
                spawnVisual(Vector3(state[0] - 17.0, state[1] + 36.0, 7.0), context),
                spawnVisual(Vector3(state[0], state[1] + 36.0, 7.0), context),
                spawnVisual(Vector3(state[0] + 17.0, state[1] + 36.0, 7.0), context)
            ];
        }
    }

    func spawnVisual(position, context) {
        return context.world.spawn([
            Transform(position: position, scale: Vector3(2, 2, 2)),
            Sprite()
        ]);
    }

    func presentAttack(peer, state, context) {
        var previous = ArenaGame.lastPresentedAttack[peer];
        if (previous != null && previous != state[4]) {
            var oldSword = ArenaGame.swords[peer];
            if (oldSword != null) context.world.commands.despawn(oldSword[0]);
            var sword = spawnVisual(Vector3(state[0], state[1], 8.0), context);
            ArenaGame.swords[peer] = [sword, 0.18, state[3], state[0], state[1]];
        }
        ArenaGame.lastPresentedAttack[peer] = state[4];
    }

    func updateVisual(row, context) {
        for (var peer in ArenaGame.players.keys()) {
            var player = ArenaGame.players[peer];
            if (row.id == ArenaGame.playerEntities[peer]) {
                row.transform.position = [player[0], player[1], 4.0];
                row.transform.scale = [42.0, 46.0, 1.0];
                row.sprite.flipX = player[3] == 2;
                var alpha = 1.0;
                if (player[2] <= 0) alpha = 0.25;
                row.sprite.tintColor = ArenaGame.playerColor(player[7], alpha);
            }

            var hearts = ArenaGame.heartEntities[peer];
            if (hearts != null) {
                var heartIndex = 0;
                while (heartIndex < 3) {
                    if (row.id == hearts[heartIndex]) {
                        row.transform.position = [player[0] + (heartIndex - 1) * 17.0, player[1] + 36.0, 7.0];
                        row.transform.scale = [11.0, 11.0, 1.0];
                        if (heartIndex < player[2]) row.sprite.tintColor = [1.0, 0.16, 0.22, 1.0];
                        else row.sprite.tintColor = [0.25, 0.25, 0.3, 0.65];
                    }
                    heartIndex += 1;
                }
            }

            var sword = ArenaGame.swords[peer];
            if (sword != null) {
                if (row.id == sword[0]) {
                    sword[1] -= context.deltaTime;
                    var offsetX = 0.0;
                    var offsetY = 0.0;
                    if (sword[2] == 0) offsetY = 34.0;
                    if (sword[2] == 1) offsetY = -34.0;
                    if (sword[2] == 2) offsetX = -34.0;
                    if (sword[2] == 3) offsetX = 34.0;
                    row.transform.position = [sword[3] + offsetX, sword[4] + offsetY, 8.0];
                    if (sword[2] < 2) row.transform.scale = [8.0, 38.0, 1.0];
                    else row.transform.scale = [38.0, 8.0, 1.0];
                    row.sprite.tintColor = [0.92, 0.94, 1.0, sword[1] / 0.18];
                    if (sword[1] <= 0.0) {
                        context.world.commands.despawn(sword[0]);
                        ArenaGame.swords.remove(peer);
                    } else {
                        ArenaGame.swords[peer] = sword;
                    }
                }
            }
        }
    }
}
