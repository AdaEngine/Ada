import { ArenaGame, ArenaPlayer } from "./ArenaState.ada";

@after(id: "arena.gameplay")
@system(scheduler: "update", id: "arena.presentation")
class ArenaPresentationSystem {
    @query(ArenaPlayer) var players;
    @query(Transform, Sprite) var visuals;

    func update(context) {
        for (var row in players) {
            var peer = row.arenaPlayer.peer;
            var state = [
                row.arenaPlayer.x, row.arenaPlayer.y, row.arenaPlayer.health,
                row.arenaPlayer.facing, row.arenaPlayer.attackSequence,
                row.arenaPlayer.respawn, row.arenaPlayer.variant
            ];
            ensureVisuals(peer, state, context);
            presentAttack(peer, state, context);
            ArenaGame.presentedPlayers[peer] = state;
        }

        for (var row in visuals) {
            updateVisual(row, context);
        }
    }

    func ensureVisuals(peer, state, context) {
        if (ArenaGame.playerEntities[peer] == null) {
            ArenaGame.playerEntities[peer] = spawnVisual(
                Vector3(state[0], state[1], 4.0),
                context,
                playerTexture(state[6])
            );
        }
        if (ArenaGame.heartEntities[peer] == null) {
            ArenaGame.heartEntities[peer] = [
                spawnVisual(Vector3(state[0] - 17.0, state[1] + 36.0, 7.0), context, null),
                spawnVisual(Vector3(state[0], state[1] + 36.0, 7.0), context, null),
                spawnVisual(Vector3(state[0] + 17.0, state[1] + 36.0, 7.0), context, null)
            ];
        }
    }

    func playerTexture(variant) {
        if (variant == 1) return "@res://Tiles/tile_0097.png";
        if (variant == 2) return "@res://Tiles/tile_0098.png";
        if (variant == 3) return "@res://Tiles/tile_0100.png";
        return "@res://Tiles/tile_0096.png";
    }

    func spawnVisual(position, context, texture) {
        return context.world.spawn([
            Transform(position: position, scale: Vector3(2, 2, 2)),
            Sprite(texture: texture)
        ]);
    }

    func presentAttack(peer, state, context) {
        var previous = ArenaGame.lastPresentedAttack[peer];
        if (previous != null && previous != state[4]) {
            var oldSword = ArenaGame.swords[peer];
            if (oldSword != null) context.world.commands.despawn(oldSword[0]);
            var sword = spawnVisual(Vector3(state[0], state[1], 8.0), context, "@res://Tiles/tile_0103.png");
            ArenaGame.swords[peer] = [sword, 0.18, state[3], state[0], state[1]];
        }
        ArenaGame.lastPresentedAttack[peer] = state[4];
    }

    func updateVisual(row, context) {
        for (var peer in ArenaGame.presentedPlayers.keys()) {
            var player = ArenaGame.presentedPlayers[peer];
            if (row.id == ArenaGame.playerEntities[peer]) {
                row.transform.position = [player[0], player[1], 4.0];
                row.transform.scale = [2.625, 2.625, 1.0];
                row.sprite.flipX = player[3] == 2;
                var alpha = 1.0;
                if (player[2] <= 0) alpha = 0.25;
                row.sprite.tintColor = [1.0, 1.0, 1.0, alpha];
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
                    row.transform.scale = [2.125, 2.125, 1.0];
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
