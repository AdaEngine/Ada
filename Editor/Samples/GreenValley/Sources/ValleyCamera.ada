import { Walker } from "./Walker.ada";

@system(id: "valley.camera")
class ValleyCamera {
    @res(optional: true) var input: Input;
    @query(Walker, Transform) var cameras;

    func update(context) {
        if (!input.available()) return;
        var dt = Math.clamp(context.deltaTime, 0.0, 0.1);
        for (var row in cameras) {
            var p = row.transform.position;
            var dz = input.getActionStrength("Forward") - input.getActionStrength("Back");
            var dx = input.getActionStrength("Right") - input.getActionStrength("Left");
            if (input.isActionJustPressed("FreeFlight")) {
                row.walker.route = row.walker.route == 3 ? 0 : 3;
            } else if (input.isActionJustPressed("Walk") || input.isActionJustPressed("Fly")) {
                row.walker.route = input.isActionJustPressed("Fly") ? 2 : 1;
                row.walker.elapsed = 0.0;
            }
            var free = row.walker.route == 3;
            if (!free && (dx != 0.0 || dz != 0.0)) row.walker.route = 0;
            var dy = free ? input.getActionStrength("Ascend") - input.getActionStrength("Descend") : 0.0;
            var speed = free ? (input.isActionPressed("Sprint") ? 90.0 : 32.0) : 6.0;
            var step = dt * speed / Math.max(1.0, Math.sqrt(dx * dx + dy * dy + dz * dz));
            var x = Math.clamp(p[0] + dx * step, -1998.0, 1998.0);
            var z = Math.clamp(p[2] + dz * step, -1998.0, 1998.0);
            var eye = 2.1;
            if (row.walker.route > 0 && !free) {
                row.walker.elapsed += dt;
                var fly = row.walker.route == 2;
                z = Math.clamp(-300.0 + row.walker.elapsed * (fly ? 45.0 : 7.0), -1998.0, 1650.0);
                x = 36.0 * Math.sin(z / 180.0);
                if (fly) {
                    x += 105.0 * Math.sin(row.walker.elapsed / 12.0);
                    eye = 100.0;
                }
            }
            var h = 46.0 * Math.cos(z / 290.0) + 29.0 * Math.sin(x / 240.0 + z / 410.0);
            h += 65.0 * (1.0 - Math.cos(x / 350.0)) + 8.0 * Math.sin(z / 87.0 + x / 95.0);
            var y = free ? Math.clamp(p[1] + dy * step, h + eye, 1200.0) : h + eye;
            row.transform.position = [x, y, z];
        }
    }
}
