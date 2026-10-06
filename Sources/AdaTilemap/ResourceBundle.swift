import AdaUtils
import Foundation

extension Bundle {
    static var adaModule: Bundle {
        #if os(Android)
            AndroidResourceBundle.bundle(named: "AdaEngine_AdaTilemap")
        #else
            .module
        #endif
    }
}
