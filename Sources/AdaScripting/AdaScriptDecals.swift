@_spi(Scripting) import AdaScene
import Gravity
import Math
#if canImport(GravityAOT)
import GravityAOT
#endif

enum AdaScriptDecalArgument {
    case integer(Int)
    case number(Double)
    case string(String)
    case list([Self])
    case null
    case invalid

    init(gravity value: GSValue, depth: Int = 0) {
        if value.isInteger, let integer = Int(exactly: value.toInteger) {
            self = .integer(integer)
        } else if value.isDouble {
            self = .number(value.toDouble)
        } else if value.isString {
            self = .string(value.toString)
        } else if value.isNull || value.isUndefined {
            self = .null
        } else if depth < 2, value.isList, value.toList.count <= 4 {
            self = .list(value.toList.map { Self(gravity: $0, depth: depth + 1) })
        } else {
            self = .invalid
        }
    }

    #if canImport(GravityAOT)
    init(native value: NativeValue, depth: Int = 0) {
        switch value {
        case let .integer(value): self = Int(exactly: value).map(Self.integer) ?? .invalid
        case let .double(value): self = .number(value)
        case let .string(value): self = .string(value)
        case .null: self = .null
        case let .list(values) where depth < 2 && values.count <= 4: self = .list(values.map { Self(native: $0, depth: depth + 1) })
        default: self = .invalid
        }
    }
    #endif

    private var float: Float? {
        switch self {
        case let .integer(value): Float(value)
        case let .number(value) where Float(value).isFinite: Float(value)
        default: nil
        }
    }

    private var vector: Vector3? {
        guard case let .list(values) = self, values.count == 3,
              let x = values[0].float, let y = values[1].float, let z = values[2].float else { return nil }
        return Vector3(x, y, z)
    }

    static func place(_ arguments: [Self]) -> Decal3DCommands.Operation? {
        guard arguments.count == 4, case let .integer(receiver) = arguments[0], receiver >= 0,
              case let .string(image) = arguments[1], case let .list(projector) = arguments[2], projector.count == 3,
              let point = projector[0].vector, let normal = projector[1].vector, let size = projector[2].vector,
              size.x > 0, size.y > 0, size.z > 0, case let .list(options) = arguments[3] else { return nil }
        let rotation = options.first ?? .null
        let degrees: Float
        if case .null = rotation {
            degrees = 0
        } else if let value = rotation.float {
            degrees = value
        } else {
            return nil
        }
        guard let frame = Decal3D.Projector.surfaceFrame(point: point, normal: normal, rotationDegrees: degrees),
              let images = images(color: image, options: Array(options.dropFirst())) else { return nil }
        return .place(receiver, .init(transform: frame, size: size), images)
    }

    static func update(_ arguments: [Self]) -> Decal3DCommands.Operation? {
        guard arguments.count == 4, case let .integer(receiver) = arguments[0], receiver >= 0,
              case let .string(handle) = arguments[1], case let .string(image) = arguments[2],
              case let .list(options) = arguments[3], let images = images(color: image, options: options) else { return nil }
        return .update(receiver, handle, images)
    }

    static func remove(_ arguments: [Self]) -> Decal3DCommands.Operation? {
        guard arguments.count == 2, case let .integer(receiver) = arguments[0], receiver >= 0,
              case let .string(handle) = arguments[1] else { return nil }
        return .remove(receiver, handle)
    }

    private static func images(color: String, options: [Self]) -> Decal3DImages? {
        guard options.count <= 3, !color.isEmpty, color.utf8.count <= 4_096 else {
            return nil
        }
        var images = Decal3DImages(color: color)
        for (index, value) in options.enumerated() {
            switch (index, value) {
            case (_, .null): continue
            case (0, .integer(let priority)): images.priority = priority
            case (1, .string(let image)) where image.utf8.count <= 4_096: images.normal = image.isEmpty ? nil : image
            case (2, .string(let image)) where image.utf8.count <= 4_096: images.roughness = image.isEmpty ? nil : image
            default: return nil
            }
        }
        return images
    }
}

func enqueueScriptDecal(_ operation: Decal3DCommands.Operation?, in commands: Decal3DCommands?) -> String {
    guard let commands else {
        return ""
    }
    if let operation {
        return commands.enqueue(operation)
    }
    return commands.rejectInvalidArguments()
}

func scriptDecalResult(_ request: String, in commands: Decal3DCommands?) -> AdaScriptAsyncResult? {
    guard let commands else {
        return .failure("unsupportedBackend", message: "This world does not support 3D decal commands.")
    }
    guard let result = commands.takeResult(request) else {
        return nil
    }
    if result.errorCode.isEmpty {
        return .success(result.value, committed: true)
    }
    return .failure(result.errorCode, message: result.message)
}
