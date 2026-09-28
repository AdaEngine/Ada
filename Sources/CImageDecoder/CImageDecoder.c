#include "CImageDecoder.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_NO_FAILURE_STRINGS
#include "Vendor/stb_image.h"

int ada_image_can_decode(const unsigned char *data, int length) {
    int width, height, channels;
    return stbi_info_from_memory(data, length, &width, &height, &channels);
}

unsigned char *ada_image_decode(const unsigned char *data, int length, int *width, int *height) {
    int channels;
    return stbi_load_from_memory(data, length, width, height, &channels, STBI_rgb_alpha);
}

void ada_image_free(unsigned char *pixels) {
    stbi_image_free(pixels);
}
