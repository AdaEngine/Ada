#ifndef ada_text_shaper_h
#define ada_text_shaper_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

typedef struct ada_shaped_glyph_s {
    uint32_t glyphIndex;
    uint32_t cluster;
    double xAdvance;
    double yAdvance;
    double xOffset;
    double yOffset;
} ada_shaped_glyph_t;

typedef struct ada_shaped_text_s {
    ada_shaped_glyph_t *glyphs;
    int glyphCount;
} ada_shaped_text_t;

typedef struct ada_font_variation_axis_s {
    uint32_t tag;
    double value;
} ada_font_variation_axis_t;

typedef enum ada_text_direction_e {
    ADA_TEXT_DIRECTION_NATURAL = -1,
    ADA_TEXT_DIRECTION_LEFT_TO_RIGHT = 0,
    ADA_TEXT_DIRECTION_RIGHT_TO_LEFT = 1
} ada_text_direction_t;

ada_shaped_text_t *ada_text_shape_utf8(const char *fontPath, const char *text, int textLength);
ada_shaped_text_t *ada_text_shape_utf8_with_variations(
    const char *fontPath,
    const char *text,
    int textLength,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
);
ada_shaped_text_t *ada_text_shape_utf8_with_direction_and_variations(
    const char *fontPath,
    const char *text,
    int textLength,
    ada_text_direction_t direction,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
);
void ada_shaped_text_destroy(ada_shaped_text_t *shapedText);

#ifdef __cplusplus
}
#endif

#endif
