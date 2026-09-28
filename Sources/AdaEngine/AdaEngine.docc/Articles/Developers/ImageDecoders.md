# Loading images and adding formats

Load PNG, JPEG (`jpg` or `jpeg`), BMP and TGA images as CPU pixels using
`Image`, or load a GPU texture through `Texture2D`:

```swift
import AdaEngine

let image = try await AssetsManager.load(Image.self, at: "@res://Textures/ground.tga")
let texture = try await AssetsManager.load(Texture2D.self, at: "@res://Textures/ground.tga")
```

`Image(contentsOf:)`, `Image.decode(from:)` and `AssetsManager` use the same
decoder registry. File extensions are case insensitive and act as hints;
the encoded bytes identify the format. Built-in decoders produce RGBA8 pixels.
TGA decoding includes indexed colors, RLE, alpha and top- or bottom-origin rows.

## Registering another raster format

Implement `ImageDecoder` when another file format should produce an ordinary
`Image`. This example defines a tiny custom format: four signature bytes,
one byte each for width and height, then RGBA8 pixels in row-major order.

```swift
import AdaEngine
import Foundation

struct RawRGBAImageDecoder: ImageDecoder {
    let supportedExtensions = ["rawrgba"]

    func canDecode(_ data: Data) -> Bool {
        data.starts(with: [65, 68, 65, 73]) // "ADAI"
    }

    func decode(_ data: Data) throws -> Image {
        let bytes = Array(data)
        guard canDecode(data), bytes.count >= 6 else {
            throw ImageDecodingError.invalidData
        }
        let width = Int(bytes[4])
        let height = Int(bytes[5])
        guard width > 0, height > 0, bytes.count == 6 + width * height * 4 else {
            throw ImageDecodingError.invalidData
        }
        return Image(width: width, height: height, data: Data(bytes.dropFirst(6)))
    }
}

Image.registerDecoder(RawRGBAImageDecoder())
let image = try await AssetsManager.load(Image.self, at: "@res://Sprites/player.rawrgba")
```

Register before loading assets or building the editor's project tree. The editor
classifies image files using `Image.extensions()`, which reflects the registry.
Extensions are returned lowercase and without duplicates.

Registry access is synchronized. Decoder callbacks execute outside the lock
and may run concurrently, so implementations must protect their own mutable state.
Newer registrations take precedence among matching decoders. Registering the
same concrete decoder type replaces its previous instance; already cached assets
are unaffected. A decoder's error propagates once it recognizes the input.

Registration adds decoding only; it does not add an image encoder. WebP, GIF,
TIFF, HDR/EXR and KTX2 are not built-in raster decoders.

## Adding a different resource type

Use `Asset` and `AssetsManager.registerAssetType` for resources with a different
runtime structure, such as an Aseprite animation containing frames, durations
and tags. A custom asset type does not automatically extend the formats accepted
by `Image`. GPU texture containers with mipmaps or compressed blocks should
preserve those contents through a dedicated texture asset/loading path.
