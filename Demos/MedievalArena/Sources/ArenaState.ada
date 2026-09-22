@network_command(
    id: "medieval-arena.input",
    delivery: "unreliable_sequenced",
    channel: "input"
)
struct ArenaInputCommand {
    @network_field(1) var moveX = 0.0;
    @network_field(2) var moveY = 0.0;
    @network_field(3) var attackSequence = 0;
}

// All state and rules below belong to Medieval Arena, not to AdaEngine.
class ArenaGame {
    static var moveX = 0.0;
    static var moveY = 0.0;
    static var attackSequence = 0;
    static var snapshotClock = 0.0;

    // peer -> [x, y, health, facing, attackSequence, consumedInput, respawn, variant]
    static var players = [:];
    static var playerEntities = [:];
    static var heartEntities = [:];
    static var swords = [:];
    static var lastPresentedAttack = [:];

    static func ensurePlayer(peer, variant) {
        if (players[peer] != null) return;
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
        players[peer] = [x, y, 3, facing, 0, 0, 0.0, variant];
    }

    static func clamp(value, lower, upper) {
        if (value < lower) return lower;
        if (value > upper) return upper;
        return value;
    }

    static func playerColor(variant, alpha) {
        if (variant % 4 == 0) return [0.25, 0.72, 1.0, alpha];
        if (variant % 4 == 1) return [1.0, 0.62, 0.24, alpha];
        if (variant % 4 == 2) return [0.45, 0.92, 0.42, alpha];
        return [0.86, 0.42, 1.0, alpha];
    }
}
