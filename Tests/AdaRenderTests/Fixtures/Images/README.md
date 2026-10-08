# Image decoding fixtures

Generated specifically for AdaEngine's tests; no third-party artwork.

All images are 2 × 2 pixels. `pixels.png` and the TGA variants contain red,
green, blue and white pixels in row-major order, with alpha 255, 128, 64, 0.
`pixels.bmp` contains the same RGB colors with opaque alpha and padded,
bottom-up rows. `bottom.tga` uses bottom-up storage; `rle.tga` uses an RLE
raw packet; `repeated.tga` uses a repeated packet containing opaque red.
`palette.tga` uses indexed colors and a 32-bit palette.

`red.jpg` is an opaque red JPEG generated from a PNG with macOS `sips` at
quality 100. Tests allow JPEG rounding rather than requiring lossless pixels.
