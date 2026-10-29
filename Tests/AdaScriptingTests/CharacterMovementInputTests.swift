import AdaApp
import AdaECS
@_spi(Internal) import AdaInput
import AdaPhysics
import AdaScripting
import Math
import Testing

@MainActor
@Suite("AdaScript character movement input", .serialized)
struct CharacterMovementInputTests {
    @Test("Nested enemy traversal preserves the outer character after every key press", arguments: [false, true])
    func movingCharacter(breakInnerLoop: Bool) async throws {
        CharacterController3DComponent.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        class MovementRules {
            static func direction(x, z, yaw) {
                var direction = [x * Math.cos(yaw) + z * Math.sin(yaw), 0.0,
                                 -x * Math.sin(yaw) + z * Math.cos(yaw)];
                if (Math.length(direction) > 1.0) return Math.normalize(direction);
                return direction;
            }
        }
        @system(id: "movement-input")
        class MovementInput {
            @res var input: Input;
            @query(CharacterController3DComponent) var players;
            func update(context) {
                System.gcThreshold = 1;
                var x = input.getActionStrength("Right") - input.getActionStrength("Left");
                var z = input.getActionStrength("Forward") - input.getActionStrength("Back");
                for (var row in players) {
                    var actorID = row.id;
                    for (var stance in players) {
                        if (stance.id == row.id) { var height = stance.characterController3DComponent.height; }
                        \(breakInnerLoop ? "break;" : "")
                    }
                    assert(row.id == actorID, "Nested traversal changed the outer actor");
                    var velocity = Math.scaleVector(MovementRules.direction(x, z, 3.141592653589793), 3.5);
                    row.characterController3DComponent.desiredVelocity = velocity;
                }
            }
        }
        """, name: "CharacterMovement")
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin(actions: [
            InputAction(name: "Forward", bindings: [.key(.w)]),
            InputAction(name: "Back", bindings: [.key(.s)]),
            InputAction(name: "Left", bindings: [.key(.a)]),
            InputAction(name: "Right", bindings: [.key(.d)])
        ]).setup(in: app)
        plugin.setup(in: app)
        let entity = world.spawn { CharacterController3DComponent() }
        let other = world.spawn { CharacterController3DComponent() }
        for key in [KeyCode.w, .a, .s, .d] {
            for status in [KeyEvent.Status.down, .up] {
                world.getRefResource(Input.self).wrappedValue.receiveEvent(KeyEvent(
                    window: .empty, keyCode: key, modifiers: [], status: status, time: 0, isRepeated: false
                ))
                await world.runScheduler(.preUpdate)
                await world.runScheduler(.update)
                await world.runScheduler(.postUpdate)
                #expect(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")
                let velocity = try #require(world.get(CharacterController3DComponent.self, from: entity.id)?.desiredVelocity)
                #expect(abs(velocity.length - (status == .down ? 3.5 : 0)) < 0.001)
                #expect(world.get(CharacterController3DComponent.self, from: other.id)?.desiredVelocity == velocity)
            }
        }
    }
}
