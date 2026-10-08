//
//  atlas_font_gen.h
//  AdaEngine
//
//  Created by v.prusakov on 3/4/23.
//

#ifndef atlas_font_gen_h
#define atlas_font_gen_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/// Type of atlas image contents
typedef enum AFG_ImageType {
    /// Rendered glyphs without anti-aliasing (two colors only)
    AFG_IMAGE_TYPE_HARD_MASK,
    /// Rendered glyphs with anti-aliasing
    AFG_IMAGE_TYPE_SOFT_MASK,
    /// Signed (true) distance field
    AFG_IMAGE_TYPE_SDF,
    /// Signed pseudo-distance field
    AFG_IMAGE_TYPE_PSDF,
    /// Multi-channel signed distance field
    AFG_IMAGE_TYPE_MSDF,
    /// Multi-channel & true signed distance field
    AFG_IMAGE_TYPE_MTSDF
} AFG_ImageType;

typedef struct AtlasBitmap {
    int bitmapWidth;
    int bitmapHeight;
    void *pixels;
    int pixelsCount;
} AtlasBitmap;

/// Global metrics of a typeface (in font units).
typedef struct FontMetrics {
    /// The size of one EM.
    double emSize;
    /// The vertical position of the ascender and descender relative to the baseline.
    double ascenderY, descenderY;
    /// The vertical difference between consecutive baselines.
    double lineHeight;
    /// The vertical position and thickness of the underline.
    double underlineY, underlineThickness;
} FontMetrics;

typedef struct FontCachedGlyph {
    uint32_t codepoint;
    int glyphIndex;
    double advance;
    double atlasLeft, atlasBottom, atlasRight, atlasTop;
    double planeLeft, planeBottom, planeRight, planeTop;
} FontCachedGlyph;

typedef struct FontCachedKerning {
    uint32_t currentUnicode;
    uint32_t nextUnicode;
    double advanceDelta;
} FontCachedKerning;

typedef struct font_atlas_descriptor {
    double emFontScale;
    double minimumScale;
    int expensiveColoring;
    double angleThreshold;
    unsigned long coloringSeed;
    
    int threads;
    
    AFG_ImageType atlasImageType;
    double atlasPixelRange;
    double miterLimit;
    int includeDefaultCharset;
    const uint32_t *additionalCodepoints;
    int additionalCodepointsCount;
    const uint32_t *variationAxisTags;
    const double *variationAxisValues;
    int variationAxesCount;
} font_atlas_descriptor;

typedef struct font_handle_s font_handle_t;
typedef struct font_generator_s font_generator_t;
typedef struct font_glyph_s font_glyph_t;

struct font_generator_s* font_atlas_generator_create(const char* fontPath, const char* fontName,
                                                     struct font_atlas_descriptor fontDescriptor);
void font_atlas_generator_destroy(struct font_generator_s* generator);

struct font_handle_s* font_atlas_generator_get_font_data(struct font_generator_s* generator);
void font_handle_destroy(struct font_handle_s *fontHandle);

struct font_handle_s* font_handle_create_cached(const char* fontName,
                                                double geometryScale,
                                                FontMetrics metrics,
                                                const FontCachedGlyph* glyphs,
                                                unsigned long glyphsCount,
                                                const FontCachedKerning* kernings,
                                                unsigned long kerningsCount);

unsigned long font_handle_get_kerning_count(struct font_handle_s* fontData);
int font_handle_copy_cached_glyph(struct font_handle_s* fontData, unsigned long index, FontCachedGlyph* outGlyph);
int font_handle_copy_cached_kerning(struct font_handle_s* fontData, unsigned long index, FontCachedKerning* outKerning);

AtlasBitmap* font_atlas_generator_generate_bitmap(struct font_generator_s* generator);
void font_atlas_bitmap_destroy(AtlasBitmap* bitmap);

const char* font_geometry_get_name(struct font_handle_s* fontData);
double font_geometry_get_scale(struct font_handle_s* fontData);

unsigned long font_handle_get_glyphs_count(struct font_handle_s* fontData);

void font_handle_get_advance(struct font_handle_s* fontData, double* advance, uint32_t currentUnicode, uint32_t nextUnicode);

FontMetrics font_geometry_get_metrics(struct font_handle_s* fontData);

// MARK: GLYPH

struct font_glyph_s* font_handle_get_glyph_unicode(struct font_handle_s* fontData, uint32_t unicode);
struct font_glyph_s* font_handle_get_glyph_index(struct font_handle_s* fontData, int glyphIndex);
void font_glyph_destroy(struct font_glyph_s* glyph);
int font_glyph_get_index(struct font_glyph_s *glyph);
double font_glyph_get_advance(struct font_glyph_s *glyph);
void font_glyph_get_quad_atlas_bounds(struct font_glyph_s *glyph, double* l, double* b, double* r, double* t);
void font_glyph_get_quad_plane_bounds(struct font_glyph_s *glyph, double* pl, double* pb, double* pr, double* pt);


#ifdef __cplusplus
}
#endif

#endif /* atlas_font_gen_h */
