import AdaRender
import AdaText
import AdaUtils
import Foundation

@MainActor
struct NavigationBackButtonIcon: View {
    private static let image: Image? = {
        let relativePath = "Icons/arrow_back.png"
        #if !WASM
            for root in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
                let url = root.appendingPathComponent("AdaEngine_AdaUI.bundle").appendingPathComponent(relativePath)
                if let image = try? Image(contentsOf: url) {
                    return image
                }
            }
        #endif
        guard let resourceURL = Bundle.adaModule.resourceURL else {
            return nil
        }
        return try? Image(contentsOf: resourceURL.appendingPathComponent(relativePath))
    }()

    var body: some View {
        if let image = Self.image {
            image
                .resizable()
                .frame(width: 24, height: 24)
                // The supplied PNG has 12 transparent pixels on its right side.
                .offset(x: 6)
        } else {
            Text("<")
                .font(.system(size: 24))
                .foregroundColor(.white)
        }
    }
}
