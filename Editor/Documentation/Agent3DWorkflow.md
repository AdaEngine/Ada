# AI-assisted 3D work in Ada Studio

The mobile agent and desktop editor MCP share native model tools and offline knowledge. Start with `editor.project.context`; its `model3D` field describes formats, tools and verification limits. Desktop context also lists `authoringTools`. Tools require an open project on desktop and operate inside the project's declared Assets root. Import sources may also be under project-local Downloads.

## Inspect and validate

`editor.model.inspect` and `editor.model.validate` accept a project-relative `path`, such as `Assets/Models/Robot.glb`. Both run the production `NativeGLTFLoader` without constructing GPU resources. They report geometry counts, selected-scene rest-pose bounds at the original scale, material indexes and PBR factors, texture/image mappings, nodes, skin joints, named clips and durations, and local dependencies. Large inventories are bounded and marked `truncated`.

Validation checks dependency containment and byte budgets, native decoding, image decoding, scene hierarchy, primitive geometry and the current import profile. `editor.asset.validate` also routes GLB/glTF to this validation. This is not a complete Khronos conformance check, GPU rendering proof or animation-playback proof. It does not author or validate gameplay collision shapes.

This profile supports glTF 2.0 primitive topologies, UV0/UV1, one set of four skin influences and at most 128 joints per skin. Required Draco/Meshopt/KTX2 extensions are unsupported. Node TRS clips can use LINEAR, STEP and CUBICSPLINE interpolation; morph-weight animation is unsupported. Models and their local dependencies have a combined 128 MiB budget. JSON and decoded accessor inventories have additional bounds.

## Import and place

Call `editor.model.import` with `source: "Downloads/Robot/Robot.gltf"` and `destination: "Assets/Models"`. Validation runs before copying. Local buffers/textures are copied as one portable bundle; repeated imports choose new names and preserve existing files. Network references, missing dependencies and escaping paths/symlinks fail. The tool returns the imported `path` and `assetReference`.

Read `editor.components.describe` with query `Model3DSource`. Its `source` uses the returned `@res://` reference. Keep the required Transform and use its scale intentionally. For simple playback, set the exact inspected `animation` name, `autoplay` and `repeats`. Preserve unrelated fields, including any project-authored animation graph. When `animationGraph` is present it takes precedence over the single `animation` clip; do not silently discard it to force clip playback. Pose-graph editing is distinct from skeletal keyframe/rig authoring.

Desktop agents should use `editor.scene.get/apply` with the latest revision to place models in open scenes and retain document undo. Mobile agents use their project file tools for scene YAML. Imported meshes do not automatically receive physics bodies or colliders; read the PhysicsBody3DComponent descriptor before adding one.

## Materials and lighting

`editor.model.material.edit` accepts `path`, zero-based `material` and `settingsJSON`. Supported patch keys are `baseColorFactor` (linear RGBA), `metallicFactor`, `roughnessFactor`, `emissiveFactor` (linear RGB), `alphaMode`, `alphaCutoff` and `doubleSided`. Invalid patches fail before writing. Unpatched material fields, hierarchy, animation data and GLB binary chunks are preserved.

`editor.model.texture.assign` binds an image to `baseColor`, `normal`, `metallicRoughness`, `emissive` or `occlusion`. Inspect material indexes first. glTF roughness uses G and metallic uses B; normal and material maps are linear data, while base-color/emission textures are sRGB. `editor.texture.render` can create procedural placeholders and flat normal maps. These operations do not unwrap a mesh or bake lighting. Editing a shared model asset affects all references to it; rebuild/reload before comparing appearance.

Read exact Camera, Mesh3DComponent, light, Environment3D and physics payloads from `editor.components.describe`. Camera framing, lighting, model scale and valid UVs all matter. Use the `basic-3d-scene` example for a perspective camera, PBR cube, directional light and game3d plugin configuration.

## Knowledge and verification

`editor.skills.list` returns bundled workflow descriptions; `editor.skills.read` loads instructions by ID. The 3D packs are `ada-3d-assets`, `ada-3d-materials` and `ada-3d-animation`. Their detailed instructions are loaded when needed. `editor.docs.search/read`, `editor.api.describe`, `editor.components.describe` and `editor.examples.list/read` also work offline on both hosts.

Desktop uses `editor.build.start`, `editor.play.start`, `editor.task.status`, `editor.output.read` and `render.capture_screenshot`. Mobile uses `editor.build`, `editor.play.start`, `editor.play.capture` and `editor.image.read`. Select the tools actually advertised by the current host. Desktop asset tools exclude mobile vision analysis and direct on-disk scene assignment; desktop scene edits go through the revision/undo workflow. Save dirty asset documents before tool writes.

After validation and build, inspect a completed frame from visible Play. Exercise selected clips and compare frames at different times for animation. Isolated simulation verifies logic and keyboard/physics behavior; it does not install Model3D or prove rendering. Blender execution, 3D generation, rig editing and skeletal clip authoring are not exposed by these Studio tools.
