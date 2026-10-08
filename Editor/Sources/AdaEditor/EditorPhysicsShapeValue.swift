@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorPhysicsShapeValue {
    enum Kind: String, CaseIterable {
        case box, circle, polygon, sphere
    }

    static func kinds(is3D: Bool) -> [Kind] { is3D ? [.box, .sphere] : [.box, .circle, .polygon] }

    static func make(_ kind: Kind, is3D: Bool = false) -> EditorSceneValue {
        if is3D {
            let resource: Shape3DResource = kind == .sphere ? .generateSphere(radius: 0.5) : .generateBox()
            guard
                let data = try? JSONEncoder().encode(resource),
                let value = try? JSONDecoder().decode(EditorSceneValue.self, from: data)
            else {
                return .null
            }
            return value
        }
        let resource: Shape2DResource
        switch kind {
        case .box: resource = .generateBox()
        case .circle,
            .sphere:
            resource = .generateCircle(radius: 1)
        case .polygon: resource = .generatePolygon(vertices: [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0, 0.5)])
        }
        guard
            let data = try? JSONEncoder().encode(resource),
            let value = try? JSONDecoder().decode(EditorSceneValue.self, from: data)
        else {
            return .null
        }
        return value
    }

    static func kind(of value: EditorSceneValue) -> Kind? {
        guard case let .object(fixture) = value.value(at: ["fixture"][...]), let key = fixture.keys.first else {
            return nil
        }
        return Kind(rawValue: key)
    }

    static func path(_ kind: Kind, _ property: String) -> [String] {
        ["fixture", kind.rawValue, "_0"] + property.split(separator: ".").map(String.init)
    }

    static func isValid(_ value: EditorSceneValue) -> Bool {
        guard kind(of: value) == .polygon else {
            return true
        }
        guard case let .array(vertices) = value.value(at: path(.polygon, "verticies")[...]), vertices.count >= 3 else {
            return false
        }
        let points: [Vector2] = vertices.compactMap { vertex in
            guard
                let x = vertex.value(at: ["x"][...])?.doubleValue,
                let y = vertex.value(at: ["y"][...])?.doubleValue
            else {
                return nil
            }
            return Vector2(Float(x), Float(y))
        }
        guard points.count == vertices.count else {
            return false
        }
        for first in 1..<(points.count - 1) {
            for second in (first + 1)..<points.count {
                let a = points[first] - points[0]
                let b = points[second] - points[0]
                if abs(a.x * b.y - a.y * b.x) > 0.00001 {
                    return true
                }
            }
        }
        return false
    }
}
