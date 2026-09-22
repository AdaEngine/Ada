import AdaECS
import AdaUtils
import Math
import Testing

private enum ReflectionMode: String, CaseIterable, ReflectedEnum, Codable, Sendable {
    case idle
    case active
}

@Component
private struct ReflectedEditableComponent: Codable, Sendable {
    var isEnabled: Bool
    var count: Int
    var speed: Float
    var title: String
    var position: Vector3
    var tint: Color
    var mode: ReflectionMode

    init(
        isEnabled: Bool = true,
        count: Int = 1,
        speed: Float = 2,
        title: String = "Default",
        position: Vector3 = Vector3(1, 2, 3),
        tint: Color = .white,
        mode: ReflectionMode = .idle
    ) {
        self.isEnabled = isEnabled
        self.count = count
        self.speed = speed
        self.title = title
        self.position = position
        self.tint = tint
        self.mode = mode
    }
}

@Suite("Component reflection")
struct ComponentReflectionTests {
    @Test("component macro exposes reflected field descriptors")
    func generatedDescriptorContainsExpectedFieldKinds() throws {
        let descriptor = ReflectedEditableComponent.componentDescriptor

        #expect(descriptor.typeName == String(reflecting: ReflectedEditableComponent.self))
        #expect(descriptor.fields.map(\.key) == ["isEnabled", "count", "speed", "title", "position", "tint", "mode"])
        #expect(descriptor.fields.first { $0.key == "isEnabled" }?.kind == .bool)
        #expect(descriptor.fields.first { $0.key == "count" }?.kind == .int)
        #expect(descriptor.fields.first { $0.key == "speed" }?.kind == .float)
        #expect(descriptor.fields.first { $0.key == "title" }?.kind == .string)
        #expect(descriptor.fields.first { $0.key == "position" }?.kind == .vector3)
        #expect(descriptor.fields.first { $0.key == "position" }?.isWritable == true)
        #expect(descriptor.fields.first { $0.key == "tint" }?.kind == .color)
        #expect(descriptor.fields.first { $0.key == "mode" }?.kind == .enumeration(["idle", "active"]))
    }

    @Test("reflection registry stores descriptors by type name")
    func registryLookup() throws {
        let descriptor = ReflectedEditableComponent.componentDescriptor
        ComponentReflectionRegistry.register(descriptor)

        let registered = try #require(ComponentReflectionRegistry.descriptor(named: descriptor.typeName))
        #expect(registered.displayName == "ReflectedEditableComponent")
        #expect(registered.fields.map(\.key).contains("tint"))
    }

    @Test("component registration stores generated reflection descriptor")
    @MainActor
    func componentRegistrationStoresGeneratedReflectionDescriptor() throws {
        ReflectedEditableComponent.registerComponent()

        let registered = try #require(ComponentReflectionRegistry.descriptor(named: String(reflecting: ReflectedEditableComponent.self)))
        #expect(registered.fields.map(\.key).contains("mode"))
    }

    @Test("descriptor reads and writes component values")
    func descriptorReadWrite() throws {
        let descriptor = ReflectedEditableComponent.componentDescriptor
        let component = ReflectedEditableComponent()

        let payload = descriptor.readPayload(from: component)
        #expect(payload["isEnabled"] == .bool(true))
        #expect(payload["position"] == .array([.double(1), .double(2), .double(3)]))

        let updated = try #require(descriptor.writing(.array([.double(10), .double(20), .double(30)]), toField: "position", in: component) as? ReflectedEditableComponent)
        #expect(updated.position == Vector3(10, 20, 30))

        let enumUpdated = try #require(descriptor.writing(.string("active"), toField: "mode", in: updated) as? ReflectedEditableComponent)
        #expect(enumUpdated.mode == .active)
    }

    @Test("descriptor writes component field back to world")
    func descriptorWritesToWorld() throws {
        let descriptor = ReflectedEditableComponent.componentDescriptor
        let world = World()
        let entity = world.spawn {
            ReflectedEditableComponent()
        }

        let didWrite = descriptor.write(.double(9), toField: "speed", in: world, entity: entity.id)
        let component = try #require(world.get(ReflectedEditableComponent.self, from: entity.id))

        #expect(didWrite)
        #expect(component.speed == 9)
    }

    @Test("integer conversion rejects non-finite and out-of-range doubles")
    func integerConversionRejectsInvalidDoubles() {
        #expect(ReflectedFieldValue.double(.nan).intValue == nil)
        #expect(ReflectedFieldValue.double(.infinity).intValue == nil)
        #expect(ReflectedFieldValue.double(-.infinity).intValue == nil)
        #expect(ReflectedFieldValue.double(Double(Int.max) + 1).intValue == nil)
        #expect(ReflectedFieldValue.double(Double(Int.min)).intValue == Int.min)
        #expect(ReflectedFieldValue.double(42.75).intValue == 42)
    }

    @Test("floating-point conversion rejects non-finite and out-of-range values")
    func floatingPointConversionRejectsInvalidValues() {
        var float: Float = 1
        var double: Double = 1
        var vector = Vector3(1, 2, 3)
        var color = Color.white

        #expect(!ComponentReflection.write(.double(.nan), to: &float))
        #expect(!ComponentReflection.write(.double(.infinity), to: &float))
        #expect(!ComponentReflection.write(.double(Double(Float.greatestFiniteMagnitude) * 2), to: &float))
        #expect(ComponentReflection.write(.double(Double(Float.greatestFiniteMagnitude)), to: &float))
        #expect(!ComponentReflection.write(.double(.infinity), to: &double))
        #expect(ComponentReflection.write(.double(Double(Float.greatestFiniteMagnitude) * 2), to: &double))
        #expect(!ComponentReflection.write(.array([.double(1), .double(.nan), .double(3)]), to: &vector))
        #expect(!ComponentReflection.write(.array([.double(1), .double(1), .double(1), .double(.infinity)]), to: &color))
        #expect(float.isFinite)
        #expect(double.isFinite)
        #expect(vector == Vector3(1, 2, 3))
        #expect(color == .white)
    }
}
