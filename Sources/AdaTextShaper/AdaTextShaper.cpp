#include "ada_text_shaper.h"

#include <hb.h>
#include <hb-ot.h>

#include <cstdlib>

ada_shaped_text_t *ada_text_shape_utf8(const char *fontPath, const char *text, int textLength) {
    return ada_text_shape_utf8_with_variations(fontPath, text, textLength, nullptr, 0);
}

ada_shaped_text_t *ada_text_shape_utf8_with_variations(
    const char *fontPath,
    const char *text,
    int textLength,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
) {
    return ada_text_shape_utf8_with_direction_and_variations(
        fontPath,
        text,
        textLength,
        ADA_TEXT_DIRECTION_NATURAL,
        variationAxes,
        variationAxesCount
    );
}

static hb_font_t *prepareShapingFont(
    hb_blob_t *blob,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
) {
    if (!blob) {
        return nullptr;
    }

    hb_face_t *face = hb_face_create(blob, 0);
    hb_blob_destroy(blob);

    if (!face) {
        return nullptr;
    }

    hb_font_t *font = hb_font_create(face);
    hb_face_destroy(face);

    if (!font) {
        return nullptr;
    }

    hb_ot_font_set_funcs(font);
    unsigned int upem = hb_face_get_upem(hb_font_get_face(font));
    hb_font_set_scale(font, static_cast<int>(upem), static_cast<int>(upem));
    if (variationAxes && variationAxesCount > 0) {
        hb_variation_t *variations = static_cast<hb_variation_t *>(
            std::calloc(variationAxesCount, sizeof(hb_variation_t))
        );
        if (!variations) {
            hb_font_destroy(font);
            return nullptr;
        }

        for (int index = 0; index < variationAxesCount; index++) {
            variations[index].tag = variationAxes[index].tag;
            variations[index].value = static_cast<float>(variationAxes[index].value);
        }
        hb_font_set_variations(font, variations, static_cast<unsigned int>(variationAxesCount));
        std::free(variations);
    }

    hb_font_make_immutable(font);
    return font;
}

ada_shaping_font_t *ada_shaping_font_create(
    const char *fontPath,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
) {
    if (!fontPath) {
        return nullptr;
    }
    auto *file = hb_blob_create_from_file_or_fail(fontPath);
    if (!file) {
        return nullptr;
    }
    unsigned int size = 0;
    const char *bytes = hb_blob_get_data(file, &size);
    // Make the loaded face independent of later writes to the file or its mapping.
    auto *snapshot = hb_blob_create_or_fail(bytes, size, HB_MEMORY_MODE_DUPLICATE, nullptr, nullptr);
    hb_blob_destroy(file);
    return prepareShapingFont(snapshot, variationAxes, variationAxesCount);
}

void ada_shaping_font_destroy(ada_shaping_font_t *font) {
    if (font) {
        hb_font_destroy(font);
    }
}

ada_shaped_text_t *ada_text_shape_utf8_with_direction_and_variations(
    const char *fontPath,
    const char *text,
    int textLength,
    ada_text_direction_t direction,
    const ada_font_variation_axis_t *variationAxes,
    int variationAxesCount
) {
    if (!fontPath || !text || textLength <= 0) {
        return nullptr;
    }
    auto *font = prepareShapingFont(hb_blob_create_from_file(fontPath), variationAxes, variationAxesCount);
    auto *result = ada_shaping_font_shape_utf8(font, text, textLength, direction);
    ada_shaping_font_destroy(font);
    return result;
}

ada_shaped_text_t *ada_shaping_font_shape_utf8(
    ada_shaping_font_t *font,
    const char *text,
    int textLength,
    ada_text_direction_t direction
) {
    if (!font || !text || textLength <= 0) {
        return nullptr;
    }
    hb_buffer_t *buffer = hb_buffer_create();
    if (!buffer) {
        return nullptr;
    }

    hb_buffer_add_utf8(buffer, text, textLength, 0, textLength);
    hb_buffer_guess_segment_properties(buffer);
    if (direction != ADA_TEXT_DIRECTION_NATURAL) {
        hb_buffer_set_direction(
            buffer,
            direction == ADA_TEXT_DIRECTION_RIGHT_TO_LEFT ? HB_DIRECTION_RTL : HB_DIRECTION_LTR
        );
    }
    hb_shape(font, buffer, nullptr, 0);

    unsigned int glyphCount = 0;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);

    if (!infos || !positions || glyphCount == 0) {
        hb_buffer_destroy(buffer);
        return nullptr;
    }

    auto *result = static_cast<ada_shaped_text_t *>(std::calloc(1, sizeof(ada_shaped_text_t)));
    if (!result) {
        hb_buffer_destroy(buffer);
        return nullptr;
    }

    result->glyphs = static_cast<ada_shaped_glyph_t *>(
        std::calloc(glyphCount, sizeof(ada_shaped_glyph_t))
    );
    if (!result->glyphs) {
        std::free(result);
        hb_buffer_destroy(buffer);
        return nullptr;
    }

    // AdaText normalizes glyph geometry, advances and offsets to one em.
    const unsigned int upem = hb_face_get_upem(hb_font_get_face(font));
    const double inverseUpem = upem > 0 ? 1.0 / static_cast<double>(upem) : 1.0;
    result->glyphCount = static_cast<int>(glyphCount);
    for (unsigned int index = 0; index < glyphCount; index++) {
        result->glyphs[index].glyphIndex = infos[index].codepoint;
        result->glyphs[index].cluster = infos[index].cluster;
        result->glyphs[index].xAdvance = positions[index].x_advance * inverseUpem;
        result->glyphs[index].yAdvance = positions[index].y_advance * inverseUpem;
        result->glyphs[index].xOffset = positions[index].x_offset * inverseUpem;
        result->glyphs[index].yOffset = positions[index].y_offset * inverseUpem;
    }

    hb_buffer_destroy(buffer);
    return result;
}

void ada_shaped_text_destroy(ada_shaped_text_t *shapedText) {
    if (!shapedText) {
        return;
    }

    std::free(shapedText->glyphs);
    std::free(shapedText);
}
