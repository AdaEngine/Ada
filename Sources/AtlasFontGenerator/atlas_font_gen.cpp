//
//  atlas_font_gen.cpp
//  AdaEngine
//
//  Created by v.prusakov on 3/19/23.
//

#include "atlas_font_gen.h"
#include <msdfgen.h>
#include <msdf_atlas_gen.h>
#include "AtlasFontGenerator.h"
#include <iterator>
#include <map>
#include <string>
#include <utility>
#include <vector>

typedef struct font_handle_s {
    ada::FontData *font_data;
    struct cached_font_data_s *cached_data;
} font_handle_t;

typedef struct font_glyph_s {
    const msdf_atlas::GlyphGeometry *glyph;
    const FontCachedGlyph *cached_glyph;
} font_glyph_t;

typedef struct font_generator_s {
    ada::FontAtlasGenerator *generator;
} font_generator_t;

typedef struct cached_font_data_s {
    std::string fontName;
    double geometryScale;
    FontMetrics metrics;
    std::vector<FontCachedGlyph> glyphs;
    std::vector<FontCachedKerning> kernings;
    std::map<uint32_t, size_t> glyphsByCodepoint;
    std::map<int, size_t> glyphsByIndex;
    std::map<std::pair<uint32_t, uint32_t>, double> kerningsByCodepoint;
} cached_font_data_t;

font_generator_s* font_atlas_generator_create(const char* fontPath,
                                 const char* fontName,
                                 font_atlas_descriptor fontDescriptor) {
    auto font_generator = new ada::FontAtlasGenerator(fontPath, fontName, fontDescriptor);
    if (!font_generator->isValid()) {
        delete font_generator;
        return nullptr;
    }

    auto generator = new font_generator_s();
    generator->generator = font_generator;
    return generator;
}

void font_atlas_generator_destroy(font_generator_s* generator) {
    if (!generator) {
        return;
    }

    delete generator->generator;
    delete generator;
}

font_handle_s* font_atlas_generator_get_font_data(font_generator_s* generator) {
    if (!generator || !generator->generator) {
        return nullptr;
    }

    auto data = generator->generator->getFontData();
    if (!data) {
        return nullptr;
    }

    font_handle_s* result = new font_handle_s();
    result->font_data = data;
    result->cached_data = nullptr;
    return result;
}

void font_handle_destroy(font_handle_s *fontHandle) {
    if (!fontHandle) {
        return;
    }

    delete fontHandle->font_data;
    delete fontHandle->cached_data;
    delete fontHandle;
}

font_handle_s* font_handle_create_cached(const char* fontName,
                                         double geometryScale,
                                         FontMetrics metrics,
                                         const FontCachedGlyph* glyphs,
                                         unsigned long glyphsCount,
                                         const FontCachedKerning* kernings,
                                         unsigned long kerningsCount) {
    if (!fontName || !glyphs || glyphsCount == 0) {
        return nullptr;
    }

    auto cachedData = new cached_font_data_s();
    cachedData->fontName = fontName;
    cachedData->geometryScale = geometryScale;
    cachedData->metrics = metrics;
    cachedData->glyphs.assign(glyphs, glyphs + glyphsCount);

    if (kernings && kerningsCount > 0) {
        cachedData->kernings.assign(kernings, kernings + kerningsCount);
    }

    for (size_t index = 0; index < cachedData->glyphs.size(); index++) {
        const FontCachedGlyph& glyph = cachedData->glyphs[index];
        if (glyph.codepoint) {
            cachedData->glyphsByCodepoint[glyph.codepoint] = index;
        }
        cachedData->glyphsByIndex[glyph.glyphIndex] = index;
    }

    for (const FontCachedKerning& kerning : cachedData->kernings) {
        cachedData->kerningsByCodepoint[
            std::make_pair(kerning.currentUnicode, kerning.nextUnicode)
        ] = kerning.advanceDelta;
    }

    auto handle = new font_handle_s();
    handle->font_data = nullptr;
    handle->cached_data = cachedData;
    return handle;
}

unsigned long font_handle_get_kerning_count(struct font_handle_s* fontData) {
    if (!fontData) {
        return 0;
    }

    if (fontData->cached_data) {
        return static_cast<unsigned long>(fontData->cached_data->kernings.size());
    }

    if (!fontData->font_data) {
        return 0;
    }

    return static_cast<unsigned long>(fontData->font_data->fontGeometry.getKerning().size());
}

int font_handle_copy_cached_glyph(struct font_handle_s* fontData, unsigned long index, FontCachedGlyph* outGlyph) {
    if (!fontData || !outGlyph) {
        return 0;
    }

    if (fontData->cached_data) {
        if (index >= fontData->cached_data->glyphs.size()) {
            return 0;
        }

        *outGlyph = fontData->cached_data->glyphs[index];
        return 1;
    }

    if (!fontData->font_data || index >= fontData->font_data->glyphs.size()) {
        return 0;
    }

    const msdf_atlas::GlyphGeometry& glyph = fontData->font_data->glyphs[index];
    outGlyph->codepoint = glyph.getCodepoint();
    outGlyph->glyphIndex = glyph.getIndex();
    outGlyph->advance = glyph.getAdvance();
    glyph.getQuadAtlasBounds(
        outGlyph->atlasLeft,
        outGlyph->atlasBottom,
        outGlyph->atlasRight,
        outGlyph->atlasTop
    );
    glyph.getQuadPlaneBounds(
        outGlyph->planeLeft,
        outGlyph->planeBottom,
        outGlyph->planeRight,
        outGlyph->planeTop
    );
    return 1;
}

int font_handle_copy_cached_kerning(struct font_handle_s* fontData, unsigned long index, FontCachedKerning* outKerning) {
    if (!fontData || !outKerning) {
        return 0;
    }

    if (fontData->cached_data) {
        if (index >= fontData->cached_data->kernings.size()) {
            return 0;
        }

        *outKerning = fontData->cached_data->kernings[index];
        return 1;
    }

    if (!fontData->font_data) {
        return 0;
    }

    const std::map<std::pair<int, int>, double>& kernings = fontData->font_data->fontGeometry.getKerning();
    if (index >= kernings.size()) {
        return 0;
    }

    auto iterator = kernings.begin();
    std::advance(iterator, index);

    const msdf_atlas::GlyphGeometry* glyph1 = fontData->font_data->fontGeometry.getGlyph(
        msdfgen::GlyphIndex(iterator->first.first)
    );
    const msdf_atlas::GlyphGeometry* glyph2 = fontData->font_data->fontGeometry.getGlyph(
        msdfgen::GlyphIndex(iterator->first.second)
    );

    if (!glyph1 || !glyph2 || !glyph1->getCodepoint() || !glyph2->getCodepoint()) {
        return 0;
    }

    outKerning->currentUnicode = glyph1->getCodepoint();
    outKerning->nextUnicode = glyph2->getCodepoint();
    outKerning->advanceDelta = iterator->second;
    return 1;
}

AtlasBitmap* font_atlas_generator_generate_bitmap(font_generator_s* generator) {
    if (!generator || !generator->generator) {
        return nullptr;
    }

    return generator->generator->generateAtlasBitmap();
}

void font_atlas_bitmap_destroy(AtlasBitmap* bitmap) {
    if (!bitmap) {
        return;
    }

    free(bitmap->pixels);
    delete bitmap;
}

const char* font_geometry_get_name(font_handle_s* fontData) {
    if (fontData->cached_data) {
        return fontData->cached_data->fontName.c_str();
    }

    return fontData->font_data->fontGeometry.getName();
}

double font_geometry_get_scale(font_handle_s* fontData) {
    if (fontData->cached_data) {
        return fontData->cached_data->geometryScale;
    }

    return fontData->font_data->fontGeometry.getGeometryScale();
}

unsigned long font_handle_get_glyphs_count(struct font_handle_s* fontData) {
    if (fontData->cached_data) {
        return static_cast<unsigned long>(fontData->cached_data->glyphs.size());
    }

    return static_cast<unsigned long>(fontData->font_data->glyphs.size());
}

void font_handle_get_advance(font_handle_s* fontData, double* advance, uint32_t currentUnicode, uint32_t nextUnicode) {
    if (fontData->cached_data) {
        auto glyph = fontData->cached_data->glyphsByCodepoint.find(currentUnicode);
        auto nextGlyph = fontData->cached_data->glyphsByCodepoint.find(nextUnicode);

        if (glyph == fontData->cached_data->glyphsByCodepoint.end()
            || nextGlyph == fontData->cached_data->glyphsByCodepoint.end()) {
            return;
        }

        *advance = fontData->cached_data->glyphs[glyph->second].advance;
        auto kerning = fontData->cached_data->kerningsByCodepoint.find(std::make_pair(currentUnicode, nextUnicode));
        if (kerning != fontData->cached_data->kerningsByCodepoint.end()) {
            *advance += kerning->second;
        }
        return;
    }

    fontData->font_data->fontGeometry.getAdvance(*advance, currentUnicode, nextUnicode);
}

FontMetrics font_geometry_get_metrics(font_handle_s* fontData) {
    if (fontData->cached_data) {
        return fontData->cached_data->metrics;
    }

    auto metrics = fontData->font_data->fontGeometry.getMetrics();
    
    FontMetrics result;
    result.lineHeight = metrics.lineHeight;
    result.ascenderY = metrics.ascenderY;
    result.descenderY = metrics.descenderY;
    result.underlineY = metrics.underlineY;
    result.underlineThickness = metrics.underlineThickness;
    result.emSize = metrics.emSize;
    return result;
}

// MARK: GLYPH

font_glyph_s* font_handle_get_glyph_unicode(font_handle_s* fontData, uint32_t unicode) {
    if (fontData->cached_data) {
        auto glyph = fontData->cached_data->glyphsByCodepoint.find(unicode);
        if (glyph == fontData->cached_data->glyphsByCodepoint.end()) {
            return nullptr;
        }

        font_glyph_s* result = new font_glyph_s();
        result->glyph = nullptr;
        result->cached_glyph = &fontData->cached_data->glyphs[glyph->second];
        return result;
    }

    const msdf_atlas::GlyphGeometry* glyph = fontData->font_data->fontGeometry.getGlyph(unicode);
    
    if (!glyph)
        return nullptr;
    
    font_glyph_s* result = new font_glyph_s();
    result->glyph = glyph;
    result->cached_glyph = nullptr;
    return result;
}

font_glyph_s* font_handle_get_glyph_index(font_handle_s* fontData, int glyphIndex) {
    if (!fontData) {
        return nullptr;
    }

    if (fontData->cached_data) {
        auto glyph = fontData->cached_data->glyphsByIndex.find(glyphIndex);
        if (glyph == fontData->cached_data->glyphsByIndex.end()) {
            return nullptr;
        }

        font_glyph_s* result = new font_glyph_s();
        result->glyph = nullptr;
        result->cached_glyph = &fontData->cached_data->glyphs[glyph->second];
        return result;
    }

    if (!fontData->font_data) {
        return nullptr;
    }

    const msdf_atlas::GlyphGeometry* glyph = fontData->font_data->fontGeometry.getGlyph(
        msdfgen::GlyphIndex(glyphIndex)
    );

    if (!glyph)
        return nullptr;

    font_glyph_s* result = new font_glyph_s();
    result->glyph = glyph;
    result->cached_glyph = nullptr;
    return result;
}

void font_glyph_destroy(font_glyph_s* glyph) {
    delete glyph;
}

int font_glyph_get_index(font_glyph_s *glyph) {
    if (glyph->cached_glyph) {
        return glyph->cached_glyph->glyphIndex;
    }

    return glyph->glyph->getIndex();
}

double font_glyph_get_advance(font_glyph_s *glyph) {
    if (glyph->cached_glyph) {
        return glyph->cached_glyph->advance;
    }

    return glyph->glyph->getAdvance();
}

void font_glyph_get_quad_atlas_bounds(font_glyph_s *glyph, double* l, double* b, double* r, double* t) {
    if (glyph->cached_glyph) {
        *l = glyph->cached_glyph->atlasLeft;
        *b = glyph->cached_glyph->atlasBottom;
        *r = glyph->cached_glyph->atlasRight;
        *t = glyph->cached_glyph->atlasTop;
        return;
    }

    glyph->glyph->getQuadAtlasBounds(*l, *b, *r, *t);
}

void font_glyph_get_quad_plane_bounds(font_glyph_s *glyph, double* pl, double* pb, double* pr, double* pt) {
    if (glyph->cached_glyph) {
        *pl = glyph->cached_glyph->planeLeft;
        *pb = glyph->cached_glyph->planeBottom;
        *pr = glyph->cached_glyph->planeRight;
        *pt = glyph->cached_glyph->planeTop;
        return;
    }

    glyph->glyph->getQuadPlaneBounds(*pl, *pb, *pr, *pt);
}
