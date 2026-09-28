@replicated_component(
    id: "medieval-arena.player",
    version: 1,
    authority: "host",
    visibility: "all_peers"
)
struct ArenaPlayer {
    @network_field(1, mode: "initial_only") var peer = "";
    @network_field(2, mode: "latest", interpolate: "linear") var x = 0.0;
    @network_field(3, mode: "latest", interpolate: "linear") var y = 0.0;
    @network_field(4, mode: "state") var health = 3;
    @network_field(5, mode: "latest") var facing = 3;
    @network_field(6, mode: "latest") var attackSequence = 0;
    @network_field(7, mode: "latest", interpolate: "linear") var respawn = 0.0;
    @network_field(8, mode: "initial_only") var variant = 0;
    @local var consumedInput = 0;
}

@rpc(
    id: "medieval-arena.input",
    delivery: "unreliable_sequenced",
    channel: "input"
)
func ArenaInputCommand(
    @network_field(1) moveX = 0.0,
    @network_field(2) moveY = 0.0,
    @network_field(3) attackSequence = 0
);

// All state and rules below belong to Medieval Arena, not to AdaEngine.
class ArenaGame {
    static var moveX = 0.0;
    static var moveY = 0.0;
    static var attackSequence = 0;

    // Presentation-only cache. Authoritative and replicated state lives in ArenaPlayer.
    static var presentedPlayers = [:];
    static var playerEntities = [:];
    static var heartEntities = [:];
    static var swords = [:];
    static var lastPresentedAttack = [:];

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
