#if defined(__wasm__) && !defined(__wasm_exception_handling__)
#define __wasm_exception_handling__
#endif

#include "png.h"

png_uint_32 swift_png_image_row_stride(png_image image) {
    return PNG_IMAGE_ROW_STRIDE(image);
}

png_uint_32 swift_png_image_pixel_size(png_uint_32 format) {
    return PNG_IMAGE_PIXEL_SIZE(format);
}

png_uint_32 swift_png_image_size(png_image image) {
    return PNG_IMAGE_SIZE(image);
}

png_uint_32 swift_png_image_pixel_component_size(png_uint_32 format) {
    return PNG_IMAGE_PIXEL_COMPONENT_SIZE(format);
}

png_uint_32 swift_png_image_pixel_channels(png_uint_32 format) {
    return PNG_IMAGE_PIXEL_CHANNELS(format);
}

png_uint_32 swift_png_image_buffer_size(png_image image, png_uint_32 stride) {
    return PNG_IMAGE_BUFFER_SIZE(image, stride);
}

png_uint_32 swift_png_image_failed(png_image image) {
    return PNG_IMAGE_FAILED(image);
}

size_t swift_png_image_png_size_max(png_image image) {
    return PNG_IMAGE_PNG_SIZE_MAX(image);
}
