#if canImport(GravityAOT)
@_spi(Scripting) import AdaECS
import AdaInput
import GravityAOT

/// A scope belongs to one synchronous callback; pointers are never retained after it ends.
final class NativeCallbackScope {
    var isActive = true
    func check() throws {
        guard isActive else { throw AdaScriptError.invalidManifest("Native ECS capability is no longer valid") }
    }
}

final class NativeReadOnlyFields: NativeHostObject {
    private let values: [String: ReflectedFieldValue]
    init(_ values: [String: ReflectedFieldValue]) { self.values = values }
    func read(_ key: String) throws -> NativeValue? { values[key]?.nativeValue }
}

final class NativeSystemContext: NativeHostObject {
    private let scope: NativeCallbackScope
    private let deltaTime: Double
    private let entityID: Entity.ID?
    private let world: NativeWorldHost?
    private let assets: NativeAssetsHost?
    init(scope: NativeCallbackScope, deltaTime: Double, entityID: Entity.ID? = nil, world: NativeWorldHost? = nil, assets: NativeAssetsHost? = nil) {
        self.scope = scope
        self.deltaTime = deltaTime
        self.entityID = entityID
        self.world = world
        self.assets = assets
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        if key == "world", let world {
            return .host(world)
        }
        if key == "assets", let assets {
            return .host(assets)
        }
        if key == "deltaTime" {
            return .double(deltaTime)
        }
        if key == "entityID", let entityID {
            return .integer(Int64(entityID))
        }
        return nil
    }
}

/// Query, row and component capabilities are allocated once per query/callback,
/// then reused as the cursor advances. No Swift proxy is allocated per entity.
final class NativeQueryHost: NativeHostObject {
    private let cursor: DynamicQueryCursor
    private let scope: NativeCallbackScope
    private let row: NativeQueryRow
    init(query: PreparedAnnotatedQuery, scope: NativeCallbackScope) {
        cursor = query.query.wrappedValue.makeCursor()
        self.scope = scope
        row = NativeQueryRow(cursor: cursor, accesses: query.componentAccesses, scope: scope)
    }
    func next(state: inout UInt64) throws -> NativeValue? {
        try scope.check()
        if state == 0 { cursor.reset() }
        guard cursor.advance() else {
            return nil
        }
        state &+= 1
        return .host(row)
    }
}

final class NativeQueryRow: NativeHostObject {
    private let cursor: DynamicQueryCursor
    private let scope: NativeCallbackScope
    private let components: [String: NativeQueryComponent]
    init(cursor: DynamicQueryCursor, accesses: [AnnotatedComponentAccess], scope: NativeCallbackScope) {
        self.cursor = cursor
        self.scope = scope
        components = Dictionary(
            uniqueKeysWithValues: accesses.map {
                ($0.alias, NativeQueryComponent(cursor: cursor, access: $0, scope: scope))
            }
        )
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        if key == "id" {
            return .integer(Int64(cursor.entityID))
        }
        return components[key].map(NativeValue.host)
    }
}

final class NativeQueryComponent: NativeHostObject {
    private let cursor: DynamicQueryCursor
    private let access: AnnotatedComponentAccess
    private let scope: NativeCallbackScope
    init(cursor: DynamicQueryCursor, access: AnnotatedComponentAccess, scope: NativeCallbackScope) {
        self.cursor = cursor
        self.access = access
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        guard let field = access.fields[key] else {
            return nil
        }
        return cursor.read(componentAt: access.componentIndex, field: field)?.nativeValue
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let field = access.fields[key], let value = value.literal?.reflected else {
            return false
        }
        return cursor.write(componentAt: access.componentIndex, field: field, value: value)
    }
}

struct NativePreparedResource: Sendable {
    enum Storage: Sendable {
        case reflected(DynamicResource, [String: ReflectedComponentField])
        case compiled(ResMut<AdaScriptNativeResources>, NativeResourceSchema)
        case input(Res<Input?>)
    }
    let propertyName: String
    let optional: Bool
    let storage: Storage
    var parameter: any SystemParameter {
        switch storage {
        case .reflected(let p, _): p
        case .compiled(let p, _): p
        case .input(let p): p
        }
    }
    func bridge(scope: NativeCallbackScope) throws -> NativeValue {
        switch storage {
        case .input(let parameter):
            if parameter.wrappedValue == nil && !optional {
                throw AdaScriptError.invalidManifest("Required Input resource is missing")
            }
            return parameter.wrappedValue.map { .host(NativeInputHost(input: $0, scope: scope)) } ?? .null
        case .reflected(let parameter, let fields):
            if !parameter.isAvailable {
                if optional {
                    return .null
                }
                throw AdaScriptError.invalidManifest("Required native resource '\(propertyName)' is missing")
            }
            return .host(NativeReflectedResource(parameter: parameter, fields: fields, scope: scope))
        case .compiled(let parameter, let schema):
            if parameter.wrappedValue.values[schema.identifier] == nil {
                if optional {
                    return .null
                }
                throw AdaScriptError.invalidManifest("Required compiled resource '\(schema.name)' is missing")
            }
            return .host(NativeCompiledResource(parameter: parameter, schema: schema, scope: scope))
        }
    }
}

final class NativeReflectedResource: NativeHostObject {
    private let parameter: DynamicResource
    private let fields: [String: ReflectedComponentField]
    private let scope: NativeCallbackScope
    init(parameter: DynamicResource, fields: [String: ReflectedComponentField], scope: NativeCallbackScope) {
        self.parameter = parameter
        self.fields = fields
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        guard let field = fields[key] else {
            return nil
        }
        return parameter.read(field: field)?.nativeValue
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let field = fields[key], let value = value.literal?.reflected else {
            return false
        }
        return parameter.write(field: field, value: value)
    }
}

final class NativeCompiledResource: NativeHostObject {
    private var parameter: ResMut<AdaScriptNativeResources>
    private let schema: NativeResourceSchema
    private let scope: NativeCallbackScope
    init(parameter: ResMut<AdaScriptNativeResources>, schema: NativeResourceSchema, scope: NativeCallbackScope) {
        self.parameter = parameter
        self.schema = schema
        self.scope = scope
    }
    func read(_ key: String) throws -> NativeValue? {
        try scope.check()
        return parameter.wrappedValue.values[schema.identifier]?[key]?.nativeValue
    }
    func write(_ key: String, value: NativeValue) throws -> Bool {
        try scope.check()
        guard let defaultValue = schema.defaults[key], let value = value.literal?.reflected,
            nativeFieldCompatible(defaultValue, value)
        else { return false }
        parameter.wrappedValue.values[schema.identifier]?[key] = value
        return true
    }
}
func nativeFieldCompatible(_ current: ReflectedFieldValue, _ value: ReflectedFieldValue) -> Bool {
    switch (current, value) {
    case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string): true
    default: false
    }
}
#endif
