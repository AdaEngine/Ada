import AdaUtils
import Foundation

extension Bundle {
    /// Android assets are extracted into app-private storage by the native host.
    static var adaModule: Bundle {
        #if os(Android)
            AndroidResourceBundle.bundle(named: "AdaEngine_AdaRender")
        #else
            .module
        #endif
    }
}
