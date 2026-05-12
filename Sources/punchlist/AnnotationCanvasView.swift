import AppKit

final class AnnotationCanvasView: NSView {
    var onSelectionChanged: (() -> Void)?

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

    private let image: NSImage
    private let cgImage: CGImage
    private var dragStart: NSPoint?
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bounds.fill()

        let imageRect = aspectFitRect()
        image.draw(in: imageRect)

        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let selection = selectionRect?.intersection(imageRect), !selection.isEmpty else {
            drawHint(in: imageRect)
            return
        }

        image.draw(in: imageRect)
        dimOutside(selection, in: imageRect)
        drawSelection(selection)
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
        }
        needsDisplay = true
    }

    private func aspectFitRect() -> NSRect {
        let inset = bounds.insetBy(dx: 10, dy: 10)
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
        NSColor.black.withAlphaComponent(0.54).setFill()

        NSRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: selection.minY - imageRect.minY).fill()
        NSRect(x: imageRect.minX, y: selection.maxY, width: imageRect.width, height: imageRect.maxY - selection.maxY).fill()
        NSRect(x: imageRect.minX, y: selection.minY, width: selection.minX - imageRect.minX, height: selection.height).fill()
        NSRect(x: selection.maxX, y: selection.minY, width: imageRect.maxX - selection.maxX, height: selection.height).fill()
    }

    private func drawSelection(_ rect: NSRect) {
        let black = NSBezierPath(rect: rect.insetBy(dx: -3, dy: -3))
        NSColor.black.setStroke()
        black.lineWidth = 6
        black.stroke()

        let yellow = NSBezierPath(rect: rect)
        NSColor.systemYellow.setStroke()
        yellow.lineWidth = 4
        yellow.stroke()
    }

    private func drawHint(in imageRect: NSRect) {
        let hint = "Drag a box around the UI issue"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = hint.size(withAttributes: attributes)
        let rect = NSRect(
            x: imageRect.midX - size.width / 2,
            y: imageRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        hint.draw(in: rect, withAttributes: attributes)
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
