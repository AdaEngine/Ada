import AdaEngine
import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Points are normalized to the captured image, so resizing keeps marks aligned.
struct EditorGameScreenshotMarkup: Sendable {
    var strokes: [[Point]] = []

    static func normalized(_ point: Point, in size: Size) -> Point {
        Point(min(1, max(0, point.x / max(1, size.width))), min(1, max(0, point.y / max(1, size.height))))
    }

    static func normalized(_ point: Point, in frame: Rect) -> Point {
        normalized(point - frame.origin, in: frame.size)
    }

    /// Produces the attachment shown in the feedback editor, including the original frame.
    @concurrent
    func pngData(for image: Image) async throws -> Data {
        try Task.checkCancellation()
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard image.width > 0, image.height > 0, !image.data.isEmpty,
              let source = CGImageSourceCreateWithData(try image.pngData() as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw Failure.encodingFailed }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 1, green: 0.22, blue: 0.25, alpha: 1))
        context.setFillColor(CGColor(red: 1, green: 0.22, blue: 0.25, alpha: 1))
        let lineWidth = max(2, width * 0.009)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            let start = CGPoint(x: CGFloat(first.x) * width, y: (1 - CGFloat(first.y)) * height)
            if stroke.count == 1 {
                context.fillEllipse(in: CGRect(x: start.x - lineWidth / 2, y: start.y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                context.beginPath()
                context.move(to: start)
                for point in stroke.dropFirst() {
                    context.addLine(to: CGPoint(x: CGFloat(point.x) * width, y: (1 - CGFloat(point.y)) * height))
                }
                context.strokePath()
            }
        }
        let output = NSMutableData()
        guard let marked = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, marked, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return output as Data
        #else
        throw Failure.encodingFailed
        #endif
    }

    enum Failure: Error { case encodingFailed }
}
