import MCP

enum EditorAgentAssetTools {
    static func tools() -> [Tool] {
        let string: Value = .object(["type": "string"])
        let integer: Value = .object(["type": "integer", "minimum": 1, "maximum": 4096])
        let tool = EditorMobileAgentTools.tool
        return [
            tool(
                "editor.image.read",
                "Inspect an image and send its pixels to the configured vision model to answer question. Paths are project-relative under Assets.",
                ["path": string, "question": string],
                ["path", "question"],
                true
            ),
            tool(
                "editor.image.generate",
                "Generate a texture/image through the configured image provider. Supply source to edit a reference image. Saves a validated asset; existing files are preserved.",
                ["prompt": string, "destination": string, "source": string],
                ["prompt", "destination"],
                false
            ),
            tool(
                "editor.texture.render",
                "Render an offline PNG under Assets. specJSON: width, height, pattern (solid/checker/gradient/noise/normal), colors (RGBA arrays), cellSize, seed.",
                ["path": string, "specJSON": string],
                ["path", "specJSON"],
                false
            ),
            tool("editor.atlas.read", "Read a native .atlas descriptor and validate its source images and keys.", ["path": string], ["path"], true),
            tool(
                "editor.atlas.write",
                "Write a native .atlas using descriptorJSON: images [{path,key}], margin, padding, extrude, maxSize {width,height}, powerOfTwo, sampler. Validate before writing.",
                ["path": string, "descriptorJSON": string],
                ["path", "descriptorJSON"],
                false
            ),
            tool(
                "editor.atlas.pack",
                "Pack a native atlas with the engine algorithm and save a PNG preview; return named pixel/UV regions. The .atlas retains its editable source references.",
                ["path": string, "previewPath": string],
                ["path", "previewPath"],
                false
            ),
            tool(
                "editor.tileset.create",
                "Create a native .tileset from a PNG grid. Defines every complete tile with stable sourceID 1; preserves the image. Use tileset.read for palette indexes.",
                ["path": string, "image": string, "tileWidth": integer, "tileHeight": integer],
                ["path", "image", "tileWidth", "tileHeight"],
                false
            ),
            tool("editor.tileset.read", "Read native tile sources, slicing, tile coordinates, animation metadata and palette indexes.", ["path": string], ["path"], true),
            tool(
                "editor.tileset.edit",
                "Edit tiles via operationsJSON: animate {sourceID,x,y,frames,duration,vertical}, define/remove {sourceID,x,y}. Reject removing tiles used by maps.",
                ["path": string, "operationsJSON": string],
                ["path", "operationsJSON"],
                false
            ),
            tool("editor.tilemap.read", "Read native .tilemap layers/cells and validate tile/image references.", ["path": string], ["path"], true),
            tool(
                "editor.tilemap.write",
                "Write a native .tilemap from resourceJSON. Read tilemap.read for the exact palette/layer format. Validate all cells and image/tile references.",
                ["path": string, "resourceJSON": string],
                ["path", "resourceJSON"],
                false
            ),
            tool(
                "editor.tilemap.edit",
                "Edit cells/layers with operationsJSON: addLayer {name}, paint {layer,x,y,tile}, erase {layer,x,y}, fill {layer,x,y,width,height,tile}. Zero-based palette indexes.",
                ["path": string, "operationsJSON": string],
                ["path", "operationsJSON"],
                false
            ),
            tool(
                "editor.scene.asset.assign",
                "Assign an asset to a registered scene component field, preserving other fields and adding required components. Read components.describe for names.",
                ["path": string, "entityID": string, "component": string, "field": string, "asset": string],
                ["path", "entityID", "component", "field", "asset"],
                false
            ),
            tool(
                "editor.model.texture.assign",
                "Assign an image to a glTF/GLB material channel (baseColor, normal, metallicRoughness, emissive, occlusion). Preserves geometry and embedded binary chunks.",
                ["path": string, "texture": string, "channel": string, "material": .object(["type": "integer", "minimum": 0])],
                ["path", "texture", "channel"],
                false
            ),
            tool(
                "editor.model.inspect",
                "Inspect a GLB/glTF through the native importer: scene bounds, meshes, PBR materials and texture slots, nodes, skins and named animation clips. Does not render.",
                ["path": string],
                ["path"],
                true
            ),
            tool(
                "editor.model.validate",
                "Validate GLB/glTF dependencies, geometry, images, hierarchy and the native import profile. Success is not GPU, animation playback or gameplay proof.",
                ["path": string],
                ["path"],
                true
            ),
            tool(
                "editor.model.import",
                "Import a project-local GLB/glTF from Downloads or Assets into Assets, with local dependencies and a collision-free bundle name. Returns an asset reference.",
                ["source": string, "destination": string],
                ["source", "destination"],
                false
            ),
            tool(
                "editor.model.material.edit",
                "Patch PBR factors using settingsJSON. Read editor.docs.read Agent3DWorkflow for supported fields. Preserves binary geometry; rebuild after edits.",
                ["path": string, "material": .object(["type": "integer", "minimum": 0]), "settingsJSON": string],
                ["path", "material", "settingsJSON"],
                false
            ),
            tool("editor.asset.validate", "Validate a GLB/glTF, image, .atlas, .tileset or .tilemap with native decoders and resource formats.", ["path": string], ["path"], true),
        ]
    }
}
