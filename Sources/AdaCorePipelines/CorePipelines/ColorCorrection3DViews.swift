import AdaECS
import AdaRender

/// Render-world ownership keeps baked textures out of serialized scene data.
struct ColorCorrection3DViews: Resource {
    struct Entry: Sendable {
        var curves: ColorCurves3D
        var texture: Texture2D?
    }

    var entries: [Entity.ID: Entry] = [:]

    mutating func prepare(_ settings: ColorGrading3D, view: Entity.ID) {
        guard settings.correctionMode == .curves, settings.sanitized.lutIntensity > 0 else {
            entries.removeValue(forKey: view)
            return
        }
        guard entries[view]?.curves != settings.curves else { return }
        let curves = settings.curves.sanitized
        let texture = curves == ColorCurves3D() ? nil : Texture2D(image: curves.makeLUTImage())
        entries[view] = Entry(curves: settings.curves, texture: texture)
    }

    func resolve(_ settings: ColorGrading3D, view: Entity.ID) -> (texture: Texture2D, intensity: Float)? {
        if settings.correctionMode != .curves { return settings.activeLUT }
        guard let texture = entries[view]?.texture, settings.sanitized.lutIntensity > 0 else { return nil }
        return (texture, settings.sanitized.lutIntensity)
    }
}
