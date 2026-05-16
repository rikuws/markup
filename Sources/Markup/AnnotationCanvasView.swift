import AppKit

final class AnnotationCanvasView: NSView {
    var onSelectionChanged: (() -> Void)?
    var onSelectionCompleted: (() -> Void)?

    var captureRegion: CaptureRegion? {
        guard let selectionRect else { return nil }
        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        let clipped = selectionRect.intersection(imageRect)
        guard clipped.width >= 4, clipped.height >= 4 else { return nil }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let x = ((clipped.minX - imageRect.minX) / imageRect.width) * pixelWidth
        let yFromTop = ((imageRect.maxY - clipped.maxY) / imageRect.height) * pixelHeight
        let width = (clipped.width / imageRect.width) * pixelWidth
        let height = (clipped.height / imageRect.height) * pixelHeight

        return CaptureRegion(
            x: max(0, Int(x.rounded())),
            y: max(0, Int(yFromTop.rounded())),
            width: max(1, Int(width.rounded())),
            height: max(1, Int(height.rounded()))
        )
    }

    private var image: NSImage
    private var cgImage: CGImage
    private var dragStart: NSPoint?
    private let imageCornerRadius: CGFloat = 12
    private var selectionRect: NSRect? {
        didSet {
            onSelectionChanged?()
        }
    }

    init(image: NSImage) {
        self.image = image
        self.cgImage = image.bestCGImage()
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func configure(image: NSImage, region: CaptureRegion?) {
        self.image = image
        cgImage = image.bestCGImage()
        setCaptureRegion(region)
    }

    func setCaptureRegion(_ region: CaptureRegion?) {
        guard let region else {
            selectionRect = nil
            needsDisplay = true
            return
        }

        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else {
            selectionRect = nil
            needsDisplay = true
            return
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let x = imageRect.minX + (CGFloat(region.x) / pixelWidth) * imageRect.width
        let y = imageRect.maxY - ((CGFloat(region.y + region.height) / pixelHeight) * imageRect.height)
        let width = (CGFloat(region.width) / pixelWidth) * imageRect.width
        let height = (CGFloat(region.height) / pixelHeight) * imageRect.height
        selectionRect = NSRect(x: x, y: y, width: width, height: height)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if let region = captureRegion {
            setCaptureRegion(region)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        bounds.fill()

        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        drawImageFrame(in: imageRect)

        guard let selection = selectionRect?.intersection(imageRect), !selection.isEmpty else {
            drawImageScrim(in: imageRect, alpha: 0.28)
            drawHint(in: imageRect)
            return
        }

        dimOutside(selection, in: imageRect)
        drawSelection(selection, in: imageRect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        addCursorRect(imageRect, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let imageRect = aspectFitRect()
        guard imageRect.contains(point) else { return }

        dragStart = point
        selectionRect = NSRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }

        let point = convert(event.locationInWindow, from: nil)
        let clipped = clamp(point, to: aspectFitRect())
        selectionRect = NSRect(
            x: min(dragStart.x, clipped.x),
            y: min(dragStart.y, clipped.y),
            width: abs(dragStart.x - clipped.x),
            height: abs(dragStart.y - clipped.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if let selectionRect, selectionRect.width < 4 || selectionRect.height < 4 {
            self.selectionRect = nil
        } else if captureRegion != nil {
            onSelectionCompleted?()
        }
        needsDisplay = true
    }

    private func aspectFitRect() -> NSRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard inset.width > 0, inset.height > 0 else { return .zero }

        let imageSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(inset.width / imageSize.width, inset.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return NSRect(
            x: inset.midX - size.width / 2,
            y: inset.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func dimOutside(_ selection: NSRect, in imageRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: imageCornerRadius, yRadius: imageCornerRadius).addClip()
        NSColor.black.withAlphaComponent(0.54).setFill()

        NSRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: selection.minY - imageRect.minY).fill()
        NSRect(x: imageRect.minX, y: selection.maxY, width: imageRect.width, height: imageRect.maxY - selection.maxY).fill()
        NSRect(x: imageRect.minX, y: selection.minY, width: selection.minX - imageRect.minX, height: selection.height).fill()
        NSRect(x: selection.maxX, y: selection.minY, width: imageRect.maxX - selection.maxX, height: selection.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawImageFrame(in imageRect: NSRect) {
        let framePath = NSBezierPath(roundedRect: imageRect, xRadius: imageCornerRadius, yRadius: imageCornerRadius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.46)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.black.withAlphaComponent(0.24).setFill()
        framePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        framePath.addClip()
        image.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.16).setStroke()
        framePath.lineWidth = 1
        framePath.stroke()
    }

    private func drawImageScrim(in imageRect: NSRect, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: imageCornerRadius, yRadius: imageCornerRadius).addClip()
        NSColor.black.withAlphaComponent(alpha).setFill()
        imageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelection(_ rect: NSRect, in imageRect: NSRect) {
        let radius = min(7, max(2, min(rect.width, rect.height) / 10))
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSColor.black.withAlphaComponent(0.62).setStroke()
        path.lineWidth = 7
        path.stroke()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 4
        path.stroke()

        NSColor.systemBlue.setStroke()
        path.lineWidth = 2.5
        path.stroke()

        drawCornerTicks(in: rect)
        drawDimensionBadge(for: rect, within: imageRect)
    }

    private func drawCornerTicks(in rect: NSRect) {
        guard rect.width >= 28, rect.height >= 28 else { return }

        let length = min(28, max(14, min(rect.width, rect.height) * 0.18))
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        path.move(to: NSPoint(x: rect.minX, y: rect.minY + length))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: NSPoint(x: rect.maxX - length, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: NSPoint(x: rect.maxX, y: rect.maxY - length))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: NSPoint(x: rect.minX + length, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - length))

        NSColor.white.withAlphaComponent(0.96).setStroke()
        path.lineWidth = 5
        path.stroke()

        NSColor.systemBlue.setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    private func drawDimensionBadge(for rect: NSRect, within imageRect: NSRect) {
        guard let captureRegion else { return }

        let label = "\(captureRegion.width) x \(captureRegion.height)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        let badgeSize = NSSize(width: labelSize.width + 18, height: labelSize.height + 10)
        let x = min(max(rect.minX, imageRect.minX + 10), imageRect.maxX - badgeSize.width - 10)
        let preferredY = rect.maxY + 10
        let unclampedY = preferredY + badgeSize.height <= imageRect.maxY
            ? preferredY
            : rect.maxY - badgeSize.height - 10
        let y = min(max(unclampedY, imageRect.minY + 10), imageRect.maxY - badgeSize.height - 10)
        let badgeRect = NSRect(origin: NSPoint(x: x, y: y), size: badgeSize)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 12, yRadius: 12)

        NSColor.black.withAlphaComponent(0.72).setFill()
        badgePath.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()

        let labelRect = NSRect(
            x: badgeRect.minX + 9,
            y: badgeRect.minY + 5,
            width: labelSize.width,
            height: labelSize.height
        )
        (label as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    private func drawHint(in imageRect: NSRect) {
        let hint = "Select the issue area"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (hint as NSString).size(withAttributes: attributes)
        let bubbleRect = NSRect(
            x: imageRect.midX - (textSize.width + 28) / 2,
            y: imageRect.midY - (textSize.height + 18) / 2,
            width: textSize.width + 28,
            height: textSize.height + 18
        )
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 14, yRadius: 14)

        NSColor.black.withAlphaComponent(0.58).setFill()
        bubble.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bubble.lineWidth = 1
        bubble.stroke()

        let textRect = NSRect(
            x: bubbleRect.minX + 14,
            y: bubbleRect.minY + 9,
            width: textSize.width,
            height: textSize.height
        )
        (hint as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func clamp(_ point: NSPoint, to rect: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}

extension NSImage {
    func bestCGImage() -> CGImage {
        var rect = NSRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cgImage
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width)),
            pixelsHigh: max(1, Int(size.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}
