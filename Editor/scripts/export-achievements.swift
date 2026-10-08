// Compile with Sources/AdaEditor/Achievements/EditorAchievement.swift, then pass an output directory.
import AppKit
import CoreGraphics
import Foundation

@main
struct ExportAchievements {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Achievements", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass an output directory."])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let images = output.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let symbols = ["sparkles", "globe", "play.fill", "square.and.arrow.down", "photo", "lightbulb.fill", "camera.fill",
                       "point.3.connected.trianglepath.dotted", "square.stack.3d.up.fill", "atom", "wand.and.stars", "slider.horizontal.3",
                       "film.fill", "figure.dance", "rectangle.inset.filled", "rectangle.3.group.fill", "link", "square.on.square",
                       "building.2.fill", "calendar", "42.circle", "apple.logo", "square.stack.3d.down.right.fill", "arrow.uturn.forward",
                       "arrow.left.and.right.righttriangle.left.righttriangle.right", "hand.wave.fill"]
        var records: [[String: Any]] = []
        for (index, item) in EditorAchievement.catalog.enumerated() {
            let imageName = "\(item.id.rawValue).png"
            try draw(symbol: symbols[index], secret: item.secret, index: index, to: images.appendingPathComponent(imageName))
            records.append([
                "id": item.id.rawValue, "gameCenterID": item.gameCenterID,
                "referenceName": item.englishTitle, "points": item.points, "hidden": item.secret,
                "repeatable": false, "goal": item.goal, "image": "images/\(imageName)",
                "localizations": [
                    "en-US": ["title": item.englishTitle, "preEarnedDescription": item.englishDetail,
                              "earnedDescription": "Achievement earned: \(item.englishTitle)."],
                    "ru": ["title": item.russianTitle, "preEarnedDescription": item.russianDetail,
                           "earnedDescription": "Достижение получено: \(item.russianTitle)."]
                ]
            ])
        }
        let json = try JSONSerialization.data(withJSONObject: ["bundleID": "org.adaengine.editor", "achievements": records], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("catalog.json"), options: .atomic)
        print("Exported \(records.count) achievements, \(EditorAchievement.catalog.reduce(0) { $0 + $1.points }) points, to \(output.path)")
    }

    @MainActor
    private static func draw(symbol: String, secret: Bool, index: Int, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapContext = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                            bytesPerRow: 4096, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        let accent = secret ? NSColor(calibratedRed: 0.72, green: 0.50, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)
        accent.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: NSRect(x: 122, y: 122, width: 780, height: 780)).fill()
        accent.withAlphaComponent(0.65).setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: 140, y: 140, width: 744, height: 744))
        circle.lineWidth = 5
        circle.stroke()
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 310, weight: .medium)) else {
            throw NSError(domain: "Achievements", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing symbol \(symbol)"])
        }
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        accent.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let scale = min(410 / image.size.width, 380 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        tinted.draw(in: NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 20, width: size.width, height: size.height))
        let label = String(format: "ADA  /  %02d", index + 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 30, weight: .medium), .foregroundColor: accent]
        let width = (label as NSString).size(withAttributes: attributes).width
        (label as NSString).draw(at: NSPoint(x: (1024 - width) / 2, y: 255), withAttributes: attributes)
        guard let cgImage = bitmapContext.makeImage(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
