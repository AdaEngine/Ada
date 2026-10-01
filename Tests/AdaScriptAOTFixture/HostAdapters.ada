extern var Assets;
extern var multiplayer;
@component(id: "aot.host.position")
struct HostPosition { @export var value = 5.0; }
@network_command(id: "aot.host.move", delivery: "unreliable_sequenced", channel: "input")
struct HostMove { @network_field(1) var amount = 0; }
@resource(id: "aot.host.capture", autoInsert: true)
struct HostCapture { @export var amount = 0; @export var spawned = -1; @export var asyncAmount = 0; @export var sender = ""; }
@system(id: "aot.host.system")
class HostSystem {
    @resource(Input) var input;
    @resource(HostCapture) var capture;
    @remote_commands(HostMove) var received;
    var sent = false;
    @rpc(id: "aot.host.async_move") async func AsyncMove(@network_field(1) amount: Int = 0) {
        await Tasks.nextFrame();
        capture.asyncAmount = amount;
        capture.sender = source;
    }
    func update(context) {
        if (!sent && input.available()) {
            capture.spawned = context.world.spawn([HostPosition()]);
            var move = HostMove();
            move.amount = 27;
            multiplayer.send(move);
            multiplayer.send(AsyncMove(41));
            sent = true;
        }
        for (var command in received) { capture.amount = command.value.amount; }
    }
}
class HostProbe {
    func load(context) { return Assets.loadTyped("NativeScriptAsset", "@res://probe.nativeasset"); }
    func save(context) {
        var asset: NativeScriptAsset = Assets.preload("@res://probe.nativeasset");
        return Assets.save(asset, "@user://copy.nativeasset");
    }
    func stale(context) { return context.world.reloadScene(); }
}
