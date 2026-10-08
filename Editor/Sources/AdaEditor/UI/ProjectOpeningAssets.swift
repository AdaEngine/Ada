//
//  ProjectOpeningAssets.swift
//  AdaEngine
//

@_spi(AdaEngine) import AdaEngine
import Foundation

enum ProjectOpeningAssets {
    static let adaEngineLogoResourceName = "AdaEngine"
    static let adaEngineLogoResourceExtension = "png"
    static let adaEngineLogoSubdirectory: String? = "Assets"

    static func adaEngineLogoURL(in bundle: Bundle = .editor) -> URL? {
        if let url = bundle.url(
            forResource: adaEngineLogoResourceName,
            withExtension: adaEngineLogoResourceExtension,
            subdirectory: adaEngineLogoSubdirectory
        ) {
            return url
        }

        return bundle.url(
            forResource: adaEngineLogoResourceName,
            withExtension: adaEngineLogoResourceExtension
        )
    }

    static func loadAdaEngineLogo(in bundle: Bundle = .editor) -> Image? {
        guard let url = adaEngineLogoURL(in: bundle) else {
            return nil
        }
        return try? Image(contentsOf: url)
    }
}
