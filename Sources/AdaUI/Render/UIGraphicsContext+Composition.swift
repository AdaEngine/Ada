import Math

extension UIGraphicsContext {
    /// Composes a recorded view with positive axis-aligned scaling and translation.
    /// All drawing offsets are transformed after the source view has finished layout.
    @_spi(Internal)
    public func drawContents(of source: UIGraphicsContext, transform: Transform3D) {
        let scale = max(source.environment.scaleFactor, 1)
        for command in source.getDrawCommands() {
            let transformed: DrawCommand
            switch command {
            case .beginLayer,
                .endLayer:
                // The source cache is valid before composition; its ID must not cache
                // vertices with a previous zoom or viewport transform in the destination.
                continue
            case let .pushClipRect(rect):
                let points = [
                    Vector4(rect.minX / scale, -rect.minY / scale, 0, 1),
                    Vector4(rect.maxX / scale, -rect.maxY / scale, 0, 1),
                ]
                .map { transform * $0 }
                let minX = max(0, min(points[0].x, points[1].x) * scale)
                let minY = max(0, -max(points[0].y, points[1].y) * scale)
                let maxX = max(0, max(points[0].x, points[1].x) * scale)
                let maxY = max(0, -min(points[0].y, points[1].y) * scale)
                transformed = .pushClipRect(Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            case let .pushClipPath(path, local):
                transformed = .pushClipPath(path, transform: transform * local)
            case let .drawQuad(local, texture, color):
                transformed = .drawQuad(transform: transform * local, texture: texture, color: color)
            case let .drawShaderEffect(local, material):
                transformed = .drawShaderEffect(transform: transform * local, material: material)
            case let .drawCircle(local, thickness, fade, color):
                transformed = .drawCircle(transform: transform * local, thickness: thickness, fade: fade, color: color)
            case let .drawLinearGradient(local, start, end, stops):
                transformed = .drawLinearGradient(transform: transform * local, startPoint: start, endPoint: end, stops: stops)
            case let .drawPath(path, local, mode):
                transformed = .drawPath(path, transform: transform * local, mode)
            case let .drawText(layout, local, opacity):
                transformed = .drawText(textLayout: layout, transform: transform * local, opacity: opacity)
            case let .drawGlyph(glyph, local, opacity):
                transformed = .drawGlyph(glyph, transform: transform * local, opacity: opacity)
            case let .drawGlassRect(local, halfSize, configuration, scaleFactor):
                transformed = .drawGlassRect(transform: transform * local, halfSize: halfSize, configuration: configuration, scaleFactor: scaleFactor)
            case let .drawLine(start, end, width, color):
                transformed = .drawLine(
                    start: (transform * Vector4(start, 1)).xyz,
                    end: (transform * Vector4(end, 1)).xyz,
                    lineWidth: width * transform.x.xyz.length,
                    color: color
                )
            case let .setLineWidth(width):
                transformed = .setLineWidth(width * transform.x.xyz.length)
            case .popClipRect,
                .popClipPath,
                .commit:
                transformed = command
            }
            commandQueue.push(transformed)
        }
    }
}
