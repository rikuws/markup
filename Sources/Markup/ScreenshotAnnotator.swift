import AppKit

enum ScreenshotAnnotator {
    static func annotatedImage(source: NSImage, region: CaptureRegion) -> NSImage? {
        let cgImage = source.bestCGImage()
        let width = cgImage.width
        let height = cgImage.height
        let canvasSize = CGSize(width: CGFloat(width), height: CGFloat(height))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let full = CGRect(origin: .zero, size: canvasSize)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.draw(cgImage, in: full)

        let rect = CGRect(
            x: CGFloat(region.x),
            y: CGFloat(height - region.y - region.height),
            width: CGFloat(region.width),
            height: CGFloat(region.height)
        )

        dimOutside(rect, in: context, canvasSize: canvasSize)
        drawLiquidGlassFocus(rect, in: context, canvasSize: canvasSize)

        guard let output = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }

    private static func dimOutside(_ rect: CGRect, in context: CGContext, canvasSize: CGSize) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasSize.width, height: max(0, rect.minY)))
        context.fill(CGRect(x: 0, y: rect.maxY, width: canvasSize.width, height: max(0, canvasSize.height - rect.maxY)))
        context.fill(CGRect(x: 0, y: rect.minY, width: max(0, rect.minX), height: rect.height))
        context.fill(CGRect(x: rect.maxX, y: rect.minY, width: max(0, canvasSize.width - rect.maxX), height: rect.height))
    }

    private static func drawLiquidGlassFocus(_ rect: CGRect, in context: CGContext, canvasSize: CGSize) {
        let shortest = min(canvasSize.width, canvasSize.height)
        let scale = max(1.15, min(2.4, shortest / 620))
        LiquidGlassSelectionRenderer.drawPane(rect: rect, in: context, scale: scale)
    }
}
