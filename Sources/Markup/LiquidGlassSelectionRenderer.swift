import AppKit

/// Draws the area-selection chrome as a quiet glass layer: a hairline
/// specular rim, a faint sheet of light, and small round handles. The
/// look follows Apple's Liquid Glass restraint — separation comes from
/// a soft shadow and a bright edge, not from glows or accent colors.
enum LiquidGlassSelectionRenderer {
    struct Style {
        var scale: CGFloat = 1
        var showsHandles = true
        var dimensions: String?
    }

    static func drawSelection(
        rect: CGRect,
        in context: CGContext,
        bounds: CGRect,
        style: Style = Style()
    ) {
        guard rect.width > 1, rect.height > 1 else { return }

        let scale = max(0.85, style.scale)
        let radius = cornerRadius(for: rect, scale: scale)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        drawGlassSheet(rect: rect, radius: radius, in: context)
        drawRim(rect: rect, radius: radius, scale: scale, in: context)

        if style.showsHandles {
            drawHandles(rect: rect, radius: radius, scale: scale, in: context)
        }

        if let dimensions, !dimensions.isEmpty {
            drawDimensionBadge(dimensions, for: rect, within: bounds, scale: scale, in: context)
        }

        context.restoreGState()
    }

    static func drawHint(
        _ text: String,
        centeredIn bounds: CGRect,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 32, height: textSize.height + 18)
        let badgeRect = CGRect(
            x: bounds.midX - badgeSize.width / 2,
            y: bounds.midY - badgeSize.height / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )

        drawGlassCapsule(in: badgeRect, scale: 1, in: context)

        let textRect = CGRect(
            x: badgeRect.minX + 16,
            y: badgeRect.minY + 9,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private static func cornerRadius(for rect: CGRect, scale: CGFloat) -> CGFloat {
        min(12 * scale, max(6 * scale, min(rect.width, rect.height) / 9))
    }

    private static func roundedPath(rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func stroke(
        _ path: CGPath,
        color: NSColor,
        width: CGFloat,
        in context: CGContext
    ) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    /// A whisper of material inside the selection: barely-there brightness
    /// with a slightly lighter top, so the region reads as glass without
    /// obscuring the content underneath.
    private static func drawGlassSheet(rect: CGRect, radius: CGFloat, in context: CGContext) {
        context.saveGState()
        context.addPath(roundedPath(rect: rect, radius: radius))
        context.clip()

        let colors = [
            NSColor.white.withAlphaComponent(0.07).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }

        context.restoreGState()
    }

    /// The edge of the glass: one soft shadow for separation, one bright
    /// hairline, and a top-lit specular accent. No bloom, no color fringe.
    private static func drawRim(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let path = roundedPath(rect: rect, radius: radius)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1 * scale),
            blur: 6 * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        stroke(path, color: NSColor.black.withAlphaComponent(0.22), width: 1.6 * scale, in: context)
        context.restoreGState()

        stroke(path, color: NSColor.white.withAlphaComponent(0.85), width: 1.0 * scale, in: context)

        let innerRect = rect.insetBy(dx: 1.0 * scale, dy: 1.0 * scale)
        stroke(
            roundedPath(rect: innerRect, radius: max(2, radius - 1.0 * scale)),
            color: NSColor.white.withAlphaComponent(0.14),
            width: 0.8 * scale,
            in: context
        )

        context.saveGState()
        let highlightBand = CGRect(
            x: rect.minX - 2 * scale,
            y: rect.midY,
            width: rect.width + 4 * scale,
            height: rect.height / 2 + 2 * scale
        )
        context.addRect(highlightBand)
        context.clip()
        stroke(path, color: NSColor.white.withAlphaComponent(0.55), width: 1.0 * scale, in: context)
        context.restoreGState()
    }

    /// Small round handles at the corners, sized like system crop handles.
    private static func drawHandles(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let minimum = 44 * scale
        guard rect.width >= minimum, rect.height >= minimum else { return }

        let size = 8.5 * scale
        let offset = radius * 0.29
        let centers = [
            CGPoint(x: rect.minX + offset, y: rect.minY + offset),
            CGPoint(x: rect.maxX - offset, y: rect.minY + offset),
            CGPoint(x: rect.maxX - offset, y: rect.maxY - offset),
            CGPoint(x: rect.minX + offset, y: rect.maxY - offset)
        ]

        for center in centers {
            drawHandleDot(at: center, size: size, scale: scale, in: context)
        }
    }

    private static func drawHandleDot(
        at center: CGPoint,
        size: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let dotRect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -0.8 * scale),
            blur: 3 * scale,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: dotRect)
        context.restoreGState()

        context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(max(0.5, 0.6 * scale))
        context.strokeEllipse(in: dotRect.insetBy(dx: 0.3 * scale, dy: 0.3 * scale))
    }

    private static func drawDimensionBadge(
        _ text: String,
        for rect: CGRect,
        within bounds: CGRect,
        scale: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * max(1, scale * 0.72), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let labelSize = (text as NSString).size(withAttributes: attributes)
        let badgeSize = CGSize(width: labelSize.width + 18 * scale, height: labelSize.height + 10 * scale)
        let x = min(max(rect.minX, bounds.minX + 10), bounds.maxX - badgeSize.width - 10)
        let preferredY = rect.maxY + 8 * scale
        let unclampedY = preferredY + badgeSize.height <= bounds.maxY
            ? preferredY
            : rect.maxY - badgeSize.height - 8 * scale
        let y = min(max(unclampedY, bounds.minY + 10), bounds.maxY - badgeSize.height - 10)
        let badgeRect = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)

        drawGlassCapsule(in: badgeRect, scale: scale, in: context)

        let labelRect = CGRect(
            x: badgeRect.minX + 9 * scale,
            y: badgeRect.minY + 5 * scale,
            width: labelSize.width,
            height: labelSize.height
        )
        (text as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    /// A quiet HUD capsule: dark translucent fill, hairline border, and a
    /// faint top highlight — the same family as system tooltips.
    private static func drawGlassCapsule(in rect: CGRect, scale: CGFloat, in context: CGContext) {
        let radius = rect.height / 2
        let path = roundedPath(rect: rect, radius: radius)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1.5 * scale),
            blur: 8 * scale,
            color: NSColor.black.withAlphaComponent(0.25).cgColor
        )
        context.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.72).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.midY),
                options: []
            )
        }
        context.restoreGState()

        stroke(path, color: NSColor.white.withAlphaComponent(0.22), width: 0.8 * scale, in: context)

        context.saveGState()
        context.addRect(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
        context.clip()
        stroke(path, color: NSColor.white.withAlphaComponent(0.32), width: 0.8 * scale, in: context)
        context.restoreGState()
    }
}
