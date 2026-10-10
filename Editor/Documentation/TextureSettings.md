# Texture import settings

Open an image in Studio's project navigator. Its Inspector shows Texture, Mipmaps,
Sampler, and Preview sections. Changes remain drafts until **Apply**; **Reload**
discards drafts and rereads the image and settings. Restart an existing Play
session to load newly applied settings.

Settings live beside the unchanged source image as `image.png.texture.json`.
Keep this file with the image when copying resources, exporting or committing a
project. `Image` and `Texture2D` resource loading consume these settings, including
when an image is converted into a texture programmatically. Images without a
settings file preserve their previous behavior.

- **Sampler:** Min/Mag filtering, mip filtering, Wrap U/V (and W for cubes),
  minimum and maximum LOD. LOD must satisfy `0 ≤ Min ≤ Max`.
- **Mipmaps:** generate initialized levels; count includes the base level.
  Count `0` generates the complete chain. Disabled generation uses level zero.
  Preview selects an applied mip level and reports its pixel dimensions.
- **Purpose:** Color, Normal or Data. Automatic color space uses sRGB for Color
  and Linear for Normal/Data. Explicit sRGB is available only for Color.
  Color mipmaps average linear radiance; alpha stays linear. Normal-map mipmaps
  normalize averaged tangent-space vectors.
- **Dimension:** 2D or Cube. A cube source is a horizontal strip of six square
  faces ordered **+X, −X, +Y, −Y, +Z, −Z**. Each face has an independent mip chain
  and can be selected in Preview. Load it with `AssetsManager.load(TextureCube.self,
  at: ...)` and use a cube-sampling shader. Sprite and Environment skybox texture
  fields use `Texture2D`; skyboxes expect a 2D equirectangular panorama.

The importer uploads explicit pixels for every generated level and cube face on
Metal, WebGPU and OpenGL. Metadata validation and CPU generation are shared.
Apply refuses malformed settings, invalid cube layouts, symbolic links, matching
dirty open settings documents, and image/settings changes detected on disk.

Verification covers shared import/persistence tests, production Inspector menu
interaction, a macOS Studio launch, and Metal readback of every generated cube
face/mip. WebGPU, OpenGL and mobile runtime execution remain unverified.
