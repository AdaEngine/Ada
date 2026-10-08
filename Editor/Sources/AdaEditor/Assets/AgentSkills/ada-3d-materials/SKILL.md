---
name: ada-3d-materials
description: Diagnose and edit Ada Studio 3D PBR material factors, texture channels, UVs, lights and camera framing.
allowed-tools: editor.model.inspect, editor.model.material.edit, editor.model.texture.assign, editor.texture.render, editor.components.describe, editor.scene.get, editor.scene.apply, editor.docs.read
---

# Ada Studio PBR Materials and Lighting

- Inspect the model first. Select a material by its reported index and name, not a guessed slot. Read the texture-to-image mapping and UV set indexes.
- Use `editor.model.material.edit` with a small `settingsJSON` patch. `baseColorFactor` is a linear RGBA array; metallic and roughness are numbers in [0,1]. Emission is a linear RGB factor. Preserve authored alpha mode and double-sided state unless the task needs them changed. Other material fields and embedded GLB geometry remain intact.
- `editor.model.texture.assign` takes a project-relative image path and one of `baseColor`, `normal`, `metallicRoughness`, `occlusion`, `emissive`. glTF packs roughness in G and metallic in B. Normal/occlusion/material maps are linear data; base color and emission textures are sRGB. Do not put an ordinary RGB painting into a normal slot.
- Reuse `editor.texture.render` for placeholder textures. A flat normal has RGB [0.5,0.5,1]. These tools neither unwrap UVs nor bake light; UVs must already exist in the model.
- Read exact `Mesh3DComponent`, Camera, light and Environment3D component payloads with `editor.components.describe`. Built-in primitives use scene material fields; imported models use their glTF material slots. Changing one shared model asset affects all instances that reference it.
- For black or flat-looking objects, inspect lights, roughness/metallic factors, texture references, UVs and environment configuration. For absent objects, check camera projection and framing first. Use modest changes and compare screenshots under the same camera/light conditions.
- Rebuild/reload after material changes. Verify visible Play and a completed GPU capture; import success or a screenshot of YAML does not establish appearance. On desktop, edit scene components through `editor.scene.apply` to retain revision checks and undo.
