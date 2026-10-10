/// Built-in AdaScript values and engine APIs shared by build-time analysis and
/// editor tooling. Runtime-provided component schemas extend this environment.
public extension AdaScriptTypeEnvironment {
    static var standard: Self {
        Self(
            functions: globalFunctions,
            members: standardMembers,
            values: [
                "Assets": .named("Assets"),
                "Math": .named("Math"),
                "Saves": .named("Saves"),
                "SpriteAnchor": .named("SpriteAnchorFactory"),
                "SpriteImageMode": .named("SpriteImageMode"),
                "TileOrientation": .named("TileOrientation"),
                "System": .named("System"),
                "Tasks": .named("Tasks"),
                "Time": .named("Time"),
            ]
        )
    }

    private static let globalFunctions: [String: AdaScriptCallableType] = [
        "SpriteAnchor": .init(parameters: [.float, .float], returnType: .list(.float)),
        "SpriteSliceBorder": .init(parameters: [.float, .float, .float, .float], returnType: .list(.float)),
        "assert": .init(parameters: [.bool, .string], returnType: .void),
        "exit": .init(parameters: [.int], returnType: .void),
        "input": .init(parameters: [.bool], returnType: .string),
        "nanotime": .init(parameters: [], returnType: .int),
        "print": .init(parameters: [.any], returnType: .void),
        "put": .init(parameters: [.any], returnType: .void),
    ]

    private static let standardMembers: [String: [String: AdaScriptMemberType]] = [
        "$AdaCommands": members([
            method(
                "setTileOrientation",
                parameters: [.int, .int, .list(.int), .int],
                returning: .bool,
                detail: "setTileOrientation(entityID, layer, coordinates, orientation) — enqueue a tile orientation edit"
            ),
            method(
                "despawn",
                parameters: [.int],
                returning: .bool,
                detail: "despawn(entityID) -> Bool — remove an entity through deferred commands",
                insertText: "despawn(entityID)"
            ),
            method(
                "insert",
                parameters: [.int, .string],
                returning: .bool,
                detail: "insert(entityID, componentName) -> Bool — insert a default component",
                insertText: "insert(entityID, componentName)"
            ),
            method(
                "remove",
                parameters: [.int, .string],
                returning: .bool,
                detail: "remove(entityID, componentName) -> Bool — remove a component",
                insertText: "remove(entityID, componentName)"
            ),
            method(
                "spawn",
                parameters: [.list(.any)],
                returning: .int,
                detail: "spawn(components) -> Int — spawn initialized components through deferred commands",
                insertText: "spawn(components)"
            ),
        ]),
        "$AdaEditorToolContext": members([
            property("entityCount", type: .int, detail: "Entity count in the action's scene snapshot; requires editor.documents.read"),
            property("scenePath", type: .string, detail: "Path of the active scene; requires editor.documents.read"),
            property("sceneRevision", type: .string, detail: "Revision of the active scene; requires editor.documents.read"),
            method("createEntity", parameters: [.string, .float, .float], returning: .bool,
                   detail: "createEntity(name, x, y) — stage an entity in the action's undoable batch; requires editor.documents.write"),
            method(
                "addCommand",
                parameters: [.string, .string, .string, .string],
                detail: "addCommand(id, title, category, action) — register an editor command",
                insertText: "addCommand(id: \"\", title: \"\", category: \"\", action: \"\")"
            ),
            method(
                "addContextMenuItem",
                parameters: [.string, .string, .string],
                detail: "addContextMenuItem(command, location, when) — contribute a contextual command",
                insertText: "addContextMenuItem(command: \"\", location: \"\", when: \"\")"
            ),
            method(
                "addFormatter",
                parameters: [.string, .list(.string), .bool, .string],
                detail: "addFormatter(id, languages, supportsSelection, action) — register a document formatter",
                insertText: "addFormatter(id: \"\", languages: [], supportsSelection: true, action: \"\")"
            ),
            method(
                "addMenuItem",
                parameters: [.string, .string, .int],
                detail: "addMenuItem(command, path, order) — contribute a menu item",
                insertText: "addMenuItem(command: \"\", path: \"\", order: 100)"
            ),
            method(
                "addPanel",
                parameters: [.string, .string, .string, .string],
                returning: .bool,
                detail: "addPanel(id, title, location, ui) — register a project-local .ui panel; API 1 supports right",
                insertText: "addPanel(id: \"\", title: \"\", location: \"right\", ui: \"Panel.ui\")"
            ),
            method(
                "addSetting",
                parameters: [.string, .string, .string, .any, .string],
                detail: "addSetting(id, title, type, default, scope) — register a typed setting",
                insertText: "addSetting(id: \"\", title: \"\", type: \"string\", default: \"\", scope: \"workspace\")"
            ),
            method(
                "subscribe",
                parameters: [.string, .string],
                detail: "subscribe(event, action) — subscribe to a supported editor event",
                insertText: "subscribe(event: \"\", action: \"\")"
            ),
        ]),
        "$AdaEntity": members([
            property("id", type: .int, detail: "Entity identifier")
        ]),
        "$AdaSystemContext": members([
            property("deltaTime", type: .float, detail: "Frame delta time in seconds"),
            property("world", type: .named("$AdaWorldContext"), detail: "Scoped AdaECS world access"),
        ]),
        "$AdaScriptableContext": members([
            property("deltaTime", type: .float, detail: "Frame delta time in seconds"),
            property("world", type: .named("$AdaWorldContext"), detail: "Scoped AdaECS world access"),
        ]),
        "$AdaWorldContext": members([
            method(
                "setTileOrientation",
                parameters: [.int, .int, .list(.int), .int],
                returning: .bool,
                detail: "setTileOrientation(entityID, layer, coordinates, orientation) — enqueue a tile orientation edit"
            ),
            property("commands", type: .named("$AdaCommands"), detail: "Scoped deferred world commands"),
            method(
                "changeScene",
                parameters: [.string],
                returning: .bool,
                detail: "changeScene(path) -> Bool — request a fresh scene for the next frame",
                insertText: "changeScene(\"@res://Scenes/Level.ascn\")"
            ),
            method(
                "reloadScene",
                parameters: [],
                returning: .bool,
                detail: "reloadScene() -> Bool — restart the active scene from its source"
            ),
            method(
                "spawn",
                parameters: [.list(.any)],
                returning: .int,
                detail: "spawn(components) -> Int — spawn initialized components through deferred commands",
                insertText: "spawn(components)"
            ),
        ]),
        "Assets": members([
            method("load", parameters: [.string], returning: .any, detail: "load(path) -> Asset — load and hot-reload a project asset", insertText: "load(\"@res://\")"),
            method("loadAsync", parameters: [.string], returning: .named("AssetResult"), detail: "loadAsync(path) -> AssetResult", insertText: "loadAsync(\"@res://\")"),
            method("preload", parameters: [.string], returning: .any, detail: "preload(path) -> Asset — load a statically referenced project asset", insertText: "preload(\"@res://\")"),
            method("save", parameters: [.any, .string], returning: .bool, detail: "save(asset, path) -> Bool", insertText: "save(asset, \"@user://\")"),
            method(
                "saveAsync",
                parameters: [.any, .string],
                returning: .named("OperationResult"),
                detail: "saveAsync(asset, path) -> OperationResult",
                insertText: "saveAsync(asset, \"@user://\")"
            ),
        ]),
        "Input": members([
            method("available", parameters: [], returning: .bool, detail: "available() -> Bool — whether an optional input resource is bound"),
            method("getActionStrength", parameters: [.string], returning: .float, detail: "getActionStrength(name) -> Float"),
            method("isActionJustPressed", parameters: [.string], returning: .bool, detail: "isActionJustPressed(name) -> Bool"),
            method("isActionJustReleased", parameters: [.string], returning: .bool, detail: "isActionJustReleased(name) -> Bool"),
            method("isActionPressed", parameters: [.string], returning: .bool, detail: "isActionPressed(name) -> Bool"),
        ]),
        "Math": members([
            method("clamp", parameters: [.float, .float, .float], returning: .float, detail: "clamp(value, minimum, maximum) -> Float"),
            method("distance", parameters: [.list(.float), .list(.float)], returning: .float, detail: "distance(left, right) -> Float"),
            method("dot", parameters: [.list(.float), .list(.float)], returning: .float, detail: "dot(left, right) -> Float"),
            method("length", parameters: [.list(.float)], returning: .float, detail: "length(vector) -> Float"),
            method("normalize", parameters: [.list(.float)], returning: .list(.float), detail: "normalize(vector) -> List<Float>"),
            method("saturate", parameters: [.float], returning: .float, detail: "saturate(value) -> Float"),
        ]),
        "Multiplayer": members([
            method("available", parameters: [], returning: .bool, detail: "available() -> Bool — whether an optional multiplayer resource is bound"),
            method("send", parameters: [.any], returning: .void, detail: "send(command) — send a typed multiplayer command")
        ]),
        "Saves": members([
            method("begin", parameters: [.string], returning: .named("SaveWriter"), detail: "begin(path) -> SaveWriter"),
            method("writeAsync", parameters: [.string, .string], returning: .named("SaveResult"), detail: "writeAsync(path, text) -> SaveResult"),
        ]),
        "System": members([
            method("assert", parameters: [.bool, .string], returning: .void, detail: "assert(condition, message)"),
            method("print", parameters: [.any], returning: .void, detail: "print(value)"),
            method("put", parameters: [.any], returning: .void, detail: "put(value)"),
        ]),
        "Tasks": members([
            method("promise", parameters: [], returning: .named("Promise"), detail: "promise() -> Promise"),
            method("start", parameters: [.any], returning: .named("TaskHandle"), detail: "start(task) -> TaskHandle"),
        ]),
        "Time": members([
            method("sleep", parameters: [.float], returning: .any, detail: "sleep(seconds) — suspend using game time"),
            method("sleepRealTime", parameters: [.float], returning: .any, detail: "sleepRealTime(seconds) — suspend using monotonic time"),
        ]),
        "SpriteAnchorFactory": members([
            property("center", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("bottomLeft", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("bottomCenter", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("bottomRight", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("centerLeft", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("centerRight", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("topLeft", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("topCenter", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
            property("topRight", type: .list(.float), detail: "Normalized sprite anchor, positive Y up"),
        ]),
        "SpriteImageMode": members([
            property("stretch", type: .any, detail: "Stretch the image"),
            property("fit", type: .any, detail: "Centered aspect fit"),
            property("fill", type: .any, detail: "Centered aspect fill"),
            method("sliced", parameters: [.list(.float)], returning: .any, detail: "sliced(border) — source-pixel nine-slice borders", insertText: "sliced(SpriteSliceBorder(8, 8, 8, 8))"),
            method("tiled", parameters: [.bool, .bool, .float], returning: .any, detail: "tiled(tileX, tileY, scale) — repeat selected axes", insertText: "tiled(true, true, 1)"),
        ]),
        "TileOrientation": members([
            property("identity", type: .int, detail: "Tile orientation ID 0"),
            property("rotate90", type: .int, detail: "Tile orientation ID 1"),
            property("rotate180", type: .int, detail: "Tile orientation ID 2"),
            property("rotate270", type: .int, detail: "Tile orientation ID 3"),
            property("mirrorX", type: .int, detail: "Tile orientation ID 4"),
            property("mirrorXRotate90", type: .int, detail: "Tile orientation ID 5"),
            property("mirrorXRotate180", type: .int, detail: "Tile orientation ID 6"),
            property("mirrorXRotate270", type: .int, detail: "Tile orientation ID 7"),
        ]),
        "Vector3": members([
            property("ZERO", type: .named("Vector3"), detail: "Zero three-dimensional vector"),
            property("zero", type: .named("Vector3"), detail: "Zero three-dimensional vector"),
            property("x", type: .float, detail: "X component"),
            property("y", type: .float, detail: "Y component"),
            property("z", type: .float, detail: "Z component"),
        ]),
        "Vector2": members([
            property("x", type: .float, detail: "X component"),
            property("y", type: .float, detail: "Y component"),
        ]),
        "Vector4": members([
            property("w", type: .float, detail: "W component"),
            property("x", type: .float, detail: "X component"),
            property("y", type: .float, detail: "Y component"),
            property("z", type: .float, detail: "Z component"),
        ]),
        "Quaternion": members([
            property("w", type: .float, detail: "W component"),
            property("x", type: .float, detail: "X component"),
            property("y", type: .float, detail: "Y component"),
            property("z", type: .float, detail: "Z component"),
        ]),
        "Color": members([
            property("a", type: .float, detail: "Alpha component"),
            property("b", type: .float, detail: "Blue component"),
            property("g", type: .float, detail: "Green component"),
            property("r", type: .float, detail: "Red component"),
        ]),
        "Transform": members([
            property("position", type: .list(.float), detail: "Position [x, y, z]; edit a local list and assign it back to transform.position"),
            property("rotation", type: .list(.float), detail: "Rotation quaternion [x, y, z, w]; edit a local list and assign it back"),
            property("scale", type: .list(.float), detail: "Scale [x, y, z]; edit a local list and assign it back to transform.scale"),
        ]),
        "View": members([
            viewMethod("accessibilityIdentifier", detail: "Set an AdaUI accessibility identifier"),
            viewMethod("background", detail: "Set a named or hexadecimal background color"),
            viewMethod("child", detail: "Append a child to a stack"),
            viewMethod("divider", detail: "Create an AdaUI divider"),
            viewMethod("empty", detail: "Create an empty AdaUI view"),
            viewMethod("fontSize", detail: "Set the inherited font size"),
            viewMethod("foregroundColor", detail: "Set a named or hexadecimal foreground color"),
            viewMethod("frame", detail: "Set a fixed width and height"),
            viewMethod("hStack", detail: "Create a horizontal AdaUI stack"),
            viewMethod("opacity", detail: "Set view opacity"),
            viewMethod("padding", detail: "Add equal padding on every edge"),
            viewMethod("spacer", detail: "Create a flexible AdaUI spacer"),
            viewMethod("spacing", detail: "Set stack spacing"),
            viewMethod("text", detail: "Create an AdaUI text view"),
            viewMethod("vStack", detail: "Create a vertical AdaUI stack"),
            viewMethod("zStack", detail: "Create an overlaying AdaUI stack"),
        ]),
    ]

    private static func members(_ entries: [(String, AdaScriptMemberType)]) -> [String: AdaScriptMemberType] {
        Dictionary(uniqueKeysWithValues: entries)
    }

    private static func method(
        _ name: String,
        parameters: [AdaScriptType] = [],
        returning returnType: AdaScriptType = .void,
        detail: String,
        insertText: String? = nil
    ) -> (String, AdaScriptMemberType) {
        (
            name,
            AdaScriptMemberType(
                type: returnType,
                callable: AdaScriptCallableType(parameters: parameters, returnType: returnType),
                detail: detail,
                insertText: insertText ?? "\(name)()",
                kind: .method
            )
        )
    }

    private static func property(
        _ name: String,
        type: AdaScriptType,
        detail: String
    ) -> (String, AdaScriptMemberType) {
        (name, AdaScriptMemberType(type: type, detail: detail, insertText: name))
    }

    private static func viewMethod(_ name: String, detail: String) -> (String, AdaScriptMemberType) {
        method(name, parameters: [.any], returning: .named("View"), detail: detail)
    }
}
