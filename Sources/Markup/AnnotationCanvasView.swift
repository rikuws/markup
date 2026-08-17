import AppKit
import SwiftUI

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
    private let glassTuning = SelectionGlassTuning()
    private lazy var glassPane: PassthroughHostingView<SelectionGlassPane> = {
        PassthroughHostingView(rootView: SelectionGlassPane(tuning: glassTuning))
    }()
    private let hintCapsule = PassthroughGlassView()
    private let hintLabel = NSTextField(labelWithString: "")
    private var selectionRect: NSRect? {
        didSet {
            onSelectionChanged?()
            updateOverlays()
        }
    }

    init(image: NSImage) {
        self.image = image
        self.cgImage = image.bestCGImage()
        super.init(frame: .zero)
        wantsLayer = true
        setupGlassPane()
        setupHintCapsule()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func configure(image: NSImage, region: CaptureRegion?, isSelectionOptional: Bool = false) {
        self.image = image
        cgImage = image.bestCGImage()
        hintLabel.stringValue = isSelectionOptional ? "Optional: select issue area" : "Select the issue area"
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
        } else {
            updateOverlays()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.045, alpha: 1).setFill()
        bounds.fill()

        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        drawImageFrame(in: imageRect)

        if selectionRect?.intersection(imageRect).isEmpty != false {
            drawImageScrim(in: imageRect, alpha: 0.22)
        }
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
            runBlobAnimation()
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

    // MARK: - Liquid Glass overlays

    private func setupGlassPane() {
        // `.clear` Liquid Glass on a filled rounded rect — only the outer
        // silhouette is beveled, so there is no inner bevel ring. A mask
        // then drops the interior to clear after a short rim falloff.
        glassPane.sizingOptions = []
        glassPane.wantsLayer = true
        glassPane.layer?.backgroundColor = NSColor.clear.cgColor
        glassPane.isHidden = true
        addSubview(glassPane)
    }

    private func setupHintCapsule() {
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        // The hint is a small labeled chip, not a see-through overlay, so
        // `.regular` glass keeps the text readable.
        hintCapsule.style = .regular
        hintCapsule.contentView = content
        hintCapsule.isHidden = true
        addSubview(hintCapsule)
    }

    /// Keeps the glass pane glued to the selection and the hint capsule
    /// centered over the image when nothing is selected.
    private func updateOverlays() {
        let imageRect = aspectFitRect()
        guard imageRect.width > 0, imageRect.height > 0 else {
            glassPane.isHidden = true
            hintCapsule.isHidden = true
            return
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        if let selection = selectionRect?.intersection(imageRect),
           selection.width >= 2, selection.height >= 2 {
            let cornerRadius = LiquidGlassSelectionRenderer.cornerRadius(
                shortest: min(selection.width, selection.height)
            )
            glassPane.frame = selection
            if glassTuning.cornerRadius != cornerRadius {
                glassTuning.cornerRadius = cornerRadius
            }
            glassPane.isHidden = false
            hintCapsule.isHidden = true
        } else {
            glassPane.isHidden = true
            let size = hintLabel.intrinsicContentSize
            let capsuleSize = NSSize(width: size.width + 34, height: size.height + 18)
            hintCapsule.frame = NSRect(
                x: imageRect.midX - capsuleSize.width / 2,
                y: imageRect.midY - capsuleSize.height / 2,
                width: capsuleSize.width,
                height: capsuleSize.height
            )
            hintCapsule.cornerRadius = capsuleSize.height / 2
            hintCapsule.isHidden = false
        }

        NSAnimationContext.endGrouping()
    }

    /// The fast gel settle when the pane is released: a quick squash and
    /// counter-stretch around the pane's center, like liquid finding rest.
    private func runBlobAnimation() {
        guard !glassPane.isHidden, let layer = glassPane.layer else { return }

        let bounds = glassPane.bounds
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [
            CATransform3DIdentity,
            Self.scaleAboutCenter(1.04, 0.955, bounds: bounds),
            Self.scaleAboutCenter(0.982, 1.022, bounds: bounds),
            Self.scaleAboutCenter(1.006, 0.994, bounds: bounds),
            CATransform3DIdentity
        ]
        animation.keyTimes = [0, 0.28, 0.56, 0.8, 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        animation.duration = 0.42
        layer.removeAnimation(forKey: "blob")
        layer.add(animation, forKey: "blob")
    }

    private static func scaleAboutCenter(_ sx: CGFloat, _ sy: CGFloat, bounds: CGRect) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, sx, sy, 1)
        return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
    }

    private func clamp(_ point: NSPoint, to rect: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}

/// Glass that never intercepts mouse events, so the canvas keeps
/// receiving the drag while the pane floats above it.
final class PassthroughGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Hosts the selection's Liquid Glass pane without eating mouse events.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class SelectionGlassTuning: ObservableObject {
    @Published var cornerRadius: CGFloat = LiquidGlassSelectionRenderer.cornerRadiusMax
}

/// Clear Liquid Glass fitted to the selection. A filled rounded rect keeps
/// bevels on the outer silhouette only; a mask melts that glass away after
/// a short rim so most of the selection stays clear.
private struct SelectionGlassPane: View {
    @ObservedObject var tuning: SelectionGlassTuning

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tuning.cornerRadius, style: .continuous)

        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.clear, in: shape)
            .mask {
                GlassClearFadeMask(cornerRadius: tuning.cornerRadius)
            }
            .allowsHitTesting(false)
    }
}

/// Opaque at the outer silhouette, then a short falloff so the interior
/// of the pane is fully clear. The glass shape stays a filled rounded
/// rect (outer bevels only); this mask only controls where it is visible.
private struct GlassClearFadeMask: View {
    var cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let shortest = min(proxy.size.width, proxy.size.height)
            let radius = min(cornerRadius, shortest / 2)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let melt = LiquidGlassSelectionRenderer.meltDepth(shortest: shortest)

            if shortest < melt * 2 + 8 {
                shape.fill(Color.white)
            } else {
                shape.fill(Color.white)
                    .overlay {
                        shape
                            .inset(by: melt)
                            .fill(Color.black)
                            .blur(radius: melt * 0.18)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
        }
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
