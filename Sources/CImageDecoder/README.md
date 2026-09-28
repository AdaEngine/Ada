# CImageDecoder

Memory-only JPEG, BMP and TGA decoding for AdaRender. PNG continues to use libpng.

`Vendor/stb_image.h` is the unmodified upstream stb_image v2.30 header from
[nothings/stb](https://github.com/nothings/stb), pinned to commit
`2c980bb59875b0d32144a71867fbdebb2f77cd20`.
Its MIT/public-domain license is included at the end of the header.

The wrapper disables filesystem access, unused formats and failure strings.
Decoding uses per-call buffers; no global decoder settings are modified.
