// Two views of one world. The module can host multiple independent play sessions.
class FlightState {
    static var worlds = [:];
    static func get(id) {
        var value = worlds[id];
        if (value == null) {
            value = ["open": false, "y": -220.0];
            worlds[id] = value;
        }
        return value;
    }
}

@scriptable(id: "unfold.gate", version: 1)
class Gate {
    @export var gateOpen = false;
    @export var status = "AIRLOCK / LOCKED";
    @export var droneOffset = 110.0;
    @export var gateColor = "#ff9659ff";
    @export var posture = "COMPACT";
    @component(required: true) var transform: Transform;
    @res var display: DisplayLayout;

    func ready(context) {
        FlightState.worlds[context.worldID] = ["open": false, "y": -220.0];
    }
    func update(context) {
        var flight = FlightState.get(context.worldID);
        flight["open"] = gateOpen;
        var dt = context.deltaTime;
        if (dt > 0.05) dt = 0.05;
        var p = transform.position;
        var target = 0.0;
        if (gateOpen) target = 190.0;
        p[0] = p[0] + (target - p[0]) * dt * 6.0;
        transform.position = p;
        droneOffset = -flight["y"] * 0.5;
        posture = "COMPACT";
        if (display.isExpanded) posture = "EXPANDED / CONNECTED";
        status = "AIRLOCK / LOCKED";
        gateColor = "#ff9659ff";
        if (gateOpen) {
            status = "AIRLOCK / OPEN";
            gateColor = "#50eacbff";
        }
    }
    func destroy(context) { FlightState.worlds.remove(context.worldID); }
}

@scriptable(id: "unfold.drone", version: 1)
class Drone {
    @component(required: true) var transform: Transform;
    func update(context) {
        var flight = FlightState.get(context.worldID);
        var dt = context.deltaTime;
        if (dt > 0.05) dt = 0.05;
        var p = transform.position;
        var limit = -48.0;
        if (flight["open"]) limit = 225.0;
        if (p[1] < limit) p[1] = p[1] + dt * 65.0;
        if (p[1] > limit && !flight["open"]) p[1] = limit;
        transform.position = p;
        flight["y"] = p[1];
    }
}
