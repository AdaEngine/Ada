//
//  AtlasFontGenerator.h
//  AdaEngine
//
//  Created by v.prusakov on 3/4/23.
//

#ifndef AtlasFontGenerator_h
#define AtlasFontGenerator_h

#include <msdfgen.h>
#include <msdf_atlas_gen.h>
#include <string>
#include "atlas_font_gen.h"

namespace ada {

struct FontData {
    msdf_atlas::FontGeometry fontGeometry;
    std::vector<msdf_atlas::GlyphGeometry> glyphs;
};

/// Generate font atlas from font path and specific font description.
class FontAtlasGenerator {
public:
    FontAtlasGenerator(const char* fontPath,
                       const char* fontName,
                       const font_atlas_descriptor& fontDescriptor);
    
    
    /// Returns bitmap representation.
    AtlasBitmap* generateAtlasBitmap();

    bool isValid() const {
        return m_FontData != nullptr && m_AtlasInfo.width > 0 && m_AtlasInfo.height > 0;
    }
    
    
    /// For some reasons we should store font data on Swift side.
    /// And you must delete memory when FontData isn't used anymore!
    FontData* getFontData() {
        return m_FontData;
    }
    
private:    
    FontData* m_FontData;
    
    font_atlas_descriptor m_fontDescriptor;
    
    struct {
        int width = -1;
        int height = -1;
    } m_AtlasInfo;
};

}
#endif /* AtlasFontGenerator_h */
