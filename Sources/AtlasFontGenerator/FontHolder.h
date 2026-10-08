//
//  FontHolder.h
//  AdaEngine
//
//  Created by v.prusakov on 3/4/23.
//

#ifndef FontHolder_h
#define FontHolder_h

#include <msdfgen.h>
#include <msdf_atlas_gen.h>

namespace ada {

class FontHolder {
    
public:
    FontHolder() : ft(msdfgen::initializeFreetype()), font(nullptr), fontPath(nullptr) {}
    ~FontHolder() {
        if (ft) {
            if (font)
                msdfgen::destroyFont(font);
            msdfgen::deinitializeFreetype(ft);
        }
    }
    
    bool loadFont(const char* fontPath);
    bool setVariationAxis(const char* axis, double value);
    
    msdfgen::FontHandle* getFont() {
        return font;
    }
    
private:
    msdfgen::FreetypeHandle* ft;
    msdfgen::FontHandle* font;
    const char* fontPath;
};

}

#endif /* FontHolder_h */
