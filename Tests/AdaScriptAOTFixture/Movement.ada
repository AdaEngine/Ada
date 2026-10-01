@component(id: "aot.integration.position")
struct PositionData { @export var value = 0.0; }
@resource(id: "aot.integration.time", autoInsert: true)
struct TimeData { @export var factor = 2.0; }
@system(id: "native.scale", scheduler: "update")
class ScaleSystem {
    @resource(TimeData) var time;
    func update(context) { time.factor = time.factor + 1.0; }
}
@system(id: "native.movement", scheduler: "update")
@after(id: "native.scale")
class MovementSystem {
    @query(PositionData, NativeVelocity, with: NativeMovable, without: NativeFrozen) var rows;
    @resource(TimeData) var time;
    var updates = 0;
    func update(context) {
        for (var row in rows) {
            row.positionData.value = row.positionData.value + row.nativeVelocity.value * time.factor * context.deltaTime;
        }
        updates = updates + 1;
    }
}
@scriptable(id: "aot.integration.controller", version: 1, aliases: ["NativeController"])
class Controller {
    @component(PositionData, required: true) var position;
    @resource(TimeData) var time;
    @export var health = 10;
    func ready(context) { health = health + 1; }
    func update(context) { position.value = position.value + context.deltaTime; }
    func fixedUpdate(context) { health = health + 1; }
    func event(events, context) { health = health + 2; }
    func destroy(context) { health = 0; }
}
