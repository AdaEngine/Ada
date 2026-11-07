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

    func decodedRGBAByteCount(_ data: Data) throws -> Int {
        guard canDecode(data), data.count >= 6 else {
            throw ImageDecodingError.invalidData
        }
        let header = Array(data.prefix(6)) // A fixed-size header, including for Data slices.
        let width = Int(header[4])
        let height = Int(header[5])
        let count = width * height * 4 // One-byte dimensions bound this multiplication.
        guard width > 0, height > 0, data.count == 6 + count else {
            throw ImageDecodingError.invalidData
        }
        return count
    }

    func decode(_ data: Data) throws -> Image {
        _ = try decodedRGBAByteCount(data)
        let header = Array(data.prefix(6))
        return Image(width: Int(header[4]), height: Int(header[5]), data: Data(data.dropFirst(6)))
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

## Texture arrays

Once the renderer is configured, `TextureDescriptor` can initialize a 2D texture
array. Set `textureType` to `.texture2DArray`, set `arrayLength`, and provide a
`TextureSubresource` for every slice and mip level. Images in each mip level need
matching dimensions and formats. Slice numbers start at zero. Sample the result
with a 2D-array shader binding, including when the array contains one slice.

```swift
let slices = [
    Image(width: 2, height: 2, color: .red, format: .rgba8),
    Image(width: 2, height: 2, color: .blue, format: .rgba8)
]
var descriptor = TextureDescriptor(
    width: 2, height: 2, pixelFormat: .rgba8,
    textureUsage: [.read], textureType: .texture2DArray, mipmapLevel: 1
)
descriptor.arrayLength = slices.count
descriptor.subresources = slices.enumerated().map {
    TextureSubresource(image: $0.element, mipLevel: 0, slice: $0.offset)
}
let arrayTexture = Texture2D(descriptor: descriptor)
```

## Bounded model and image imports

Model pipelines can install `ModelImportLimits` for one structured resource
request. The bounded native paths accept glTF/GLB, OBJ and static VOX data. Terrain palette readers retain their limits across actor calls,
reader forks and save adoption. The root/dependency byte limit applies before
resource reads; decoded geometry and texture preparation share a conservative
budget. Pixel checks happen before decoding, mip conversion and GPU texture creation.

Optional `.meshlets` and `.meshletlod` files share the encoded allowance. Their
parsed records and staging copies use the remaining decoded allowance after
mandatory model textures. If a derived file is invalid or exceeds these limits,
the model keeps its original geometry and materials and reports an import warning.

```swift
import AdaEngine

let limits = ModelImportLimits(
    maximumEncodedBytes: 16 * 1024 * 1024,
    maximumDecodedBytes: 64 * 1024 * 1024
)
let model = try await ModelImportContext.$limits.withValue(limits) {
    try await AssetsManager.loadFresh(ModelAsset3D.self, at: "@res://Models/rock.glb")
}
```

`decodedRGBAByteCount(_:)` must inspect only bounded header data and return the
RGBA8 pixel size without allocating pixel buffers. Check dimensions and arithmetic
before multiplying them. Built-in PNG, JPEG, BMP and TGA decoders provide this
inspection. The custom decoder above opts in too. The default implementation
rejects bounded inspection explicitly; ordinary image loading keeps its existing
behavior when no import limits are installed. Header readers must honor `Data`
slices whose `startIndex` is nonzero.

Bounded OBJ loading uses the built-in parser and meters text/token expansion before
allocation. Repeated faces and distinct materials use shared buffers and indexed
primitive selection; nonfinite coordinates reject before GPU preparation. Bounded
VOX loading admits raw records, dense grids and conservative meshing work before
allocation. It requires a static, acyclic visible hierarchy with bounded depth;
static subtree merging is unavailable under these limits. Ordinary imports without
limits preserve the existing loader/options path. Conservative estimates can reject
an asset that would fit after geometry reduction; raise the scoped limit when needed.


## Adding a different resource type

Use `Asset` and `AssetsManager.registerAssetType` for resources with a different
runtime structure, such as an Aseprite animation containing frames, durations
and tags. A custom asset type does not automatically extend the formats accepted
by `Image`. GPU texture containers with mipmaps or compressed blocks should
preserve those contents through a dedicated texture asset/loading path.
