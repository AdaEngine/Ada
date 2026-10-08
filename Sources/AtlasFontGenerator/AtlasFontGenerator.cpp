//
//  atlas_font_gen.cpp
//  AdaEngine
//
//  Created by v.prusakov on 3/4/23.
//

#include "assert.h"
#include "atlas_font_gen.h"
#include "FontHolder.h"
#include "AtlasFontGenerator.h"

#include <hb.h>
#include <hb-ot.h>

// Get from Hazel
#define LCG_MULTIPLIER 6364136223846793005ull
#define LCG_INCREMENT 1442695040888963407ull

namespace ada {

struct GenerationConfig {
    int width;
    int height;
    int threads;
    msdf_atlas::GeneratorAttributes attributes;
};

using namespace msdf_atlas;

template <typename T, typename S, int N, GeneratorFunction<S, N> GEN_FN>
AtlasBitmap* GenerateAtlas(
                                 const std::vector<GlyphGeometry>& glyphs,
                                 const FontGeometry& fontGeometry,
                                 const GenerationConfig& config
                                 )
{
    ImmediateAtlasGenerator<S, N, GEN_FN, BitmapAtlasStorage<T, N>> generator(config.width, config.height);
    generator.setAttributes(config.attributes);
    generator.setThreadCount(config.threads);
    generator.generate(glyphs.data(), (int)glyphs.size());
    
    msdfgen::BitmapConstRef<T, N> bitmap = (msdfgen::BitmapConstRef<T, N>)generator.atlasStorage();
    
    AtlasBitmap* result = new AtlasBitmap();
    result->bitmapWidth = bitmap.width;
    result->bitmapHeight = bitmap.height;
    
    void *pixels = malloc(bitmap.width * bitmap.height * sizeof(T) * N);
    memcpy(pixels, bitmap.pixels, bitmap.width * bitmap.height * sizeof(T) * N);    
    result->pixels = pixels;
    result->pixelsCount = bitmap.width * bitmap.height * sizeof(T) * N;
    
    return result;
}

static void axisTagToString(uint32_t tag, char out[5]) {
    out[0] = char((tag >> 24) & 0xff);
    out[1] = char((tag >> 16) & 0xff);
    out[2] = char((tag >> 8) & 0xff);
    out[3] = char(tag & 0xff);
    out[4] = '\0';
}

static void addShapedGlyphs(Charset& glyphset, const char* fontPath, const font_atlas_descriptor& fontDescriptor, const char* text) {
    hb_blob_t *blob = hb_blob_create_from_file(fontPath);
    if (!blob)
        return;

    hb_face_t *face = hb_face_create(blob, 0);
    hb_blob_destroy(blob);
    if (!face)
        return;

    hb_font_t *font = hb_font_create(face);
    hb_face_destroy(face);
    if (!font)
        return;

    hb_ot_font_set_funcs(font);
    unsigned int upem = hb_face_get_upem(hb_font_get_face(font));
    hb_font_set_scale(font, static_cast<int>(upem), static_cast<int>(upem));
    if (fontDescriptor.variationAxisTags && fontDescriptor.variationAxisValues && fontDescriptor.variationAxesCount > 0) {
        std::vector<hb_variation_t> variations;
        variations.reserve(fontDescriptor.variationAxesCount);
        for (int index = 0; index < fontDescriptor.variationAxesCount; index++) {
            hb_variation_t variation;
            variation.tag = fontDescriptor.variationAxisTags[index];
            variation.value = static_cast<float>(fontDescriptor.variationAxisValues[index]);
            variations.push_back(variation);
        }
        hb_font_set_variations(font, variations.data(), static_cast<unsigned int>(variations.size()));
    }

    hb_buffer_t *buffer = hb_buffer_create();
    if (!buffer) {
        hb_font_destroy(font);
        return;
    }

    hb_buffer_add_utf8(buffer, text, -1, 0, -1);
    hb_buffer_guess_segment_properties(buffer);
    hb_shape(font, buffer, nullptr, 0);

    unsigned int glyphCount = 0;
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    for (unsigned int index = 0; infos && index < glyphCount; index++) {
        glyphset.add(infos[index].codepoint);
    }

    hb_buffer_destroy(buffer);
    hb_font_destroy(font);
}

FontAtlasGenerator::FontAtlasGenerator(const char* filePath, const char* fontName, const font_atlas_descriptor& fontDescriptor) : m_FontData(new FontData()), m_fontDescriptor(fontDescriptor)
{
    FontHolder fontHandler;
    bool success = fontHandler.loadFont(filePath);
    
    if (!success || fontHandler.getFont() == nullptr) {
        delete m_FontData;
        m_FontData = nullptr;
        return;
    }

    if (fontDescriptor.variationAxisTags && fontDescriptor.variationAxisValues && fontDescriptor.variationAxesCount > 0) {
        for (int index = 0; index < fontDescriptor.variationAxesCount; index++) {
            char tagName[5];
            axisTagToString(fontDescriptor.variationAxisTags[index], tagName);
            fontHandler.setVariationAxis(tagName, fontDescriptor.variationAxisValues[index]);
        }
    }
    
    Charset charset;
    
    static const uint32_t charsetRanges[] = {
        0x0020, 0x00FF, // Basic Latin + Latin Supplement
        0x0100, 0x024F, // Latin Extended-A + B
        0x0370, 0x03FF, // Greek and Coptic
        0x0400, 0x052F, // Cyrillic + Cyrillic Supplement
        0x2000, 0x206F, // General Punctuation
        0x2070, 0x209F, // Superscripts and Subscripts
        0x20A0, 0x20CF, // Currency Symbols
        0x2100, 0x214F, // Letterlike Symbols
        0x2190, 0x21FF, // Arrows
        0x2200, 0x22FF, // Mathematical Operators
        0x2300, 0x23FF, // Miscellaneous Technical
        0x25A0, 0x25FF, // Geometric Shapes
        0x2600, 0x26FF, // Miscellaneous Symbols
        0x2DE0, 0x2DFF, // Cyrillic Extended-A
        0xA640, 0xA69F, // Cyrillic Extended-B
        0xFE00, 0xFE0F, // Variation Selectors
        0,
    };
    
    m_FontData->fontGeometry = FontGeometry(&m_FontData->glyphs);
    
    if (fontDescriptor.includeDefaultCharset) {
        for (int range = 0; charsetRanges[range]; range += 2) {
            for (uint32_t c = charsetRanges[range]; c <= charsetRanges[range + 1]; c++)
                charset.add(c);
        }
    }

    if (fontDescriptor.additionalCodepoints && fontDescriptor.additionalCodepointsCount > 0) {
        for (int i = 0; i < fontDescriptor.additionalCodepointsCount; i++)
            charset.add(fontDescriptor.additionalCodepoints[i]);
    }
    
    int loadedGlyphs = m_FontData->fontGeometry.loadCharset(fontHandler.getFont(), 1, charset);
    if (fontDescriptor.includeDefaultCharset) {
        Charset shapedGlyphset;
        addShapedGlyphs(shapedGlyphset, filePath, fontDescriptor, "fi");
        addShapedGlyphs(shapedGlyphset, filePath, fontDescriptor, "fl");
        addShapedGlyphs(shapedGlyphset, filePath, fontDescriptor, "ff");
        addShapedGlyphs(shapedGlyphset, filePath, fontDescriptor, "ffi");
        addShapedGlyphs(shapedGlyphset, filePath, fontDescriptor, "ffl");
        loadedGlyphs += m_FontData->fontGeometry.loadGlyphset(fontHandler.getFont(), 1, shapedGlyphset);
    }
    
    if (loadedGlyphs <= 0 || m_FontData->glyphs.empty()) {
        delete m_FontData;
        m_FontData = nullptr;
        return;
    }
    
    m_FontData->fontGeometry.setName(fontName);
    
    TightAtlasPacker atlasPacker;
    atlasPacker.setDimensionsConstraint(TightAtlasPacker::DimensionsConstraint::MULTIPLE_OF_FOUR_SQUARE);
    atlasPacker.setPadding(fontDescriptor.atlasImageType == AFG_ImageType::AFG_IMAGE_TYPE_MSDF || fontDescriptor.atlasImageType == AFG_ImageType::AFG_IMAGE_TYPE_MTSDF ? 0 : -1);
    
    atlasPacker.setScale(fontDescriptor.emFontScale);
    atlasPacker.setMinimumScale(12);
    atlasPacker.setPixelRange(fontDescriptor.atlasPixelRange);
    atlasPacker.setMiterLimit(fontDescriptor.miterLimit);
    
    int result = atlasPacker.pack(m_FontData->glyphs.data(), (int)m_FontData->glyphs.size());
    
    if (result != 0)
        return;
    
    atlasPacker.getDimensions(m_AtlasInfo.width, m_AtlasInfo.height);
    
    if (fontDescriptor.atlasImageType == AFG_ImageType::AFG_IMAGE_TYPE_MSDF || fontDescriptor.atlasImageType == AFG_ImageType::AFG_IMAGE_TYPE_MTSDF) {
        if (fontDescriptor.expensiveColoring) {
            Workload([&glyphs = m_FontData->glyphs, &fontDescriptor](int i, int threadNo) -> bool {
                unsigned long long glyphSeed = (LCG_MULTIPLIER * (fontDescriptor.coloringSeed ^ i) + LCG_INCREMENT) * !!fontDescriptor.coloringSeed;
                glyphs[i].edgeColoring(msdfgen::edgeColoringInkTrap, fontDescriptor.angleThreshold, glyphSeed);
                return true;
            }, (int)m_FontData->glyphs.size());
        } else {
            unsigned long glyphSeed = fontDescriptor.coloringSeed;
            for (GlyphGeometry &glyph : m_FontData->glyphs) {
                glyphSeed *= LCG_MULTIPLIER;
                glyph.edgeColoring(msdfgen::edgeColoringInkTrap, fontDescriptor.angleThreshold, glyphSeed);
            }
        }
    }

}

AtlasBitmap* FontAtlasGenerator::generateAtlasBitmap() {
    if (!isValid()) {
        return nullptr;
    }

    GenerationConfig config;
    config.width = m_AtlasInfo.width;
    config.height = m_AtlasInfo.height;
    config.threads = m_fontDescriptor.threads;
    config.attributes.config.overlapSupport = true;
    config.attributes.scanlinePass = true;
    
    switch (m_fontDescriptor.atlasImageType) {
        case AFG_ImageType::AFG_IMAGE_TYPE_HARD_MASK:
            break;
        case AFG_ImageType::AFG_IMAGE_TYPE_SOFT_MASK:
            break;
        case AFG_ImageType::AFG_IMAGE_TYPE_SDF:
            break;
        case AFG_ImageType::AFG_IMAGE_TYPE_PSDF:
            break;
        case AFG_ImageType::AFG_IMAGE_TYPE_MSDF:
            return GenerateAtlas<float, float, 3, msdfGenerator>(m_FontData->glyphs, m_FontData->fontGeometry, config);
        case AFG_ImageType::AFG_IMAGE_TYPE_MTSDF:
            return GenerateAtlas<float, float, 4, mtsdfGenerator>(m_FontData->glyphs, m_FontData->fontGeometry, config);
    }
    
    return nullptr;
}

}
