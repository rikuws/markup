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
        drawFocusFrame(rect, in: context, canvasSize: canvasSize)

        guard let output = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: output, size: NSSize(width: width, height: height))
    }

    private static func dimOutside(_ rect: CGRect, in context: CGContext, canvasSize: CGSize) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.50).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: canvasSize.width, height: max(0, rect.minY)))
        context.fill(CGRect(x: 0, y: rect.maxY, width: canvasSize.width, height: max(0, canvasSize.height - rect.maxY)))
        context.fill(CGRect(x: 0, y: rect.minY, width: max(0, rect.minX), height: rect.height))
        context.fill(CGRect(x: rect.maxX, y: rect.minY, width: max(0, canvasSize.width - rect.maxX), height: rect.height))
    }

    private static func drawFocusFrame(_ rect: CGRect, in context: CGContext, canvasSize: CGSize) {
        let baseStroke = max(4, min(9, min(canvasSize.width, canvasSize.height) / 180))
        let radius = min(max(4, baseStroke * 1.4), min(rect.width, rect.height) / 2)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: baseStroke * 1.4, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        context.setLineWidth(baseStroke + 6)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(baseStroke + 2)
        context.addPath(path)
        context.strokePath()

        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(baseStroke)
        context.addPath(path)
        context.strokePath()

        drawCornerTicks(rect, in: context, strokeWidth: baseStroke)
    }

    private static func drawCornerTicks(_ rect: CGRect, in context: CGContext, strokeWidth: CGFloat) {
        guard rect.width >= 48, rect.height >= 48 else { return }

        let length = min(42, max(22, min(rect.width, rect.height) * 0.16))
        strokeCornerTicks(rect, length: length, in: context, color: NSColor.white.withAlphaComponent(0.96), lineWidth: strokeWidth + 2)
        strokeCornerTicks(rect, length: length, in: context, color: .systemBlue, lineWidth: strokeWidth)
    }

    private static func strokeCornerTicks(
        _ rect: CGRect,
        length: CGFloat,
        in context: CGContext,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.beginPath()
        context.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        context.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        context.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        context.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        context.strokePath()

        context.restoreGState()
    }
}
