import Foundation

enum EditorComponentFieldCoding: Equatable, Sendable {
    case standard, enumCase, json, unsignedInteger, vectorObject
}

extension EditorComponentField {
    func storedValue(in payload: EditorComponentPayload) -> EditorSceneValue? {
        valuePath.isEmpty ? payload[key] : EditorSceneValue.object(payload).value(at: valuePath[...])
    }
}

extension EditorSceneValue {
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else {
            return ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func value(at path: ArraySlice<String>) -> Self? {
        guard let key = path.first else {
            return self
        }
        switch self {
        case let .object(object): return object[key]?.value(at: path.dropFirst())
        case let .array(values):
            guard let index = Int(key), values.indices.contains(index) else {
                return nil
            }
            return values[index].value(at: path.dropFirst())
        default: return nil
        }
    }

    mutating func setValue(_ value: Self, at path: ArraySlice<String>) {
        guard let key = path.first else {
            self = value
            return
        }
        if case var .array(values) = self, let index = Int(key), values.indices.contains(index) {
            values[index].setValue(value, at: path.dropFirst())
            self = .array(values)
        } else {
            var object: [String: Self] =
                if case let .object(current) = self {
                    current
                } else {
                    [:]
                }
            var child = object[key] ?? .object([:])
            child.setValue(value, at: path.dropFirst())
            object[key] = child
            self = .object(object)
        }
    }
}
