import AppKit

enum ScreenshotAnnotator {
    static func annotatedImage(source: NSImage, region: CaptureRegion) -> NSImage? {
        let cgImage = source.bestCGImage()
        let width = cgImage.width
        let height = cgImage.height

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

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: full)

        let rect = CGRect(
            x: region.x,
            y: height - region.y - region.height,
            width: region.width,
            height: region.height
        )

        context.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: max(0, Int(rect.minY))))
        context.fill(CGRect(x: 0, y: rect.maxY, width: CGFloat(width), height: CGFloat(height) - rect.maxY))
        context.fill(CGRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height))
        context.fill(CGRect(x: rect.maxX, y: rect.minY, width: CGFloat(width) - rect.maxX, height: rect.height))

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(10)
        context.stroke(rect.insetBy(dx: -5, dy: -5))

        context.setStrokeColor(NSColor.systemYellow.cgColor)
        context.setLineWidth(6)
        context.stroke(rect)

        guard let output = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }
}
