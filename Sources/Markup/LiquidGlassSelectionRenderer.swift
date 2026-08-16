import AppKit

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

        drawContactShadow(rect: rect, radius: radius, scale: scale, in: context)
        drawOuterBloom(rect: rect, radius: radius, scale: scale, in: context)
        drawGlassFill(rect: rect, radius: radius, in: context)
        drawLensingRim(rect: rect, radius: radius, scale: scale, in: context)
        drawSpecularHighlight(rect: rect, radius: radius, scale: scale, in: context)

        if style.showsHandles {
            drawHandles(rect: rect, scale: scale, in: context)
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
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 36, height: textSize.height + 22)
        let badgeRect = CGRect(
            x: bounds.midX - badgeSize.width / 2,
            y: bounds.midY - badgeSize.height / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )

        drawGlassCapsule(in: badgeRect, scale: 1.15, in: context)

        let textRect = CGRect(
            x: badgeRect.minX + 18,
            y: badgeRect.minY + 11,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private static func cornerRadius(for rect: CGRect, scale: CGFloat) -> CGFloat {
        min(18 * scale, max(8 * scale, min(rect.width, rect.height) / 7))
    }

    private static func roundedPath(rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
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

    private static func drawContactShadow(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1.5 * scale),
            blur: 10 * scale,
            color: NSColor.black.withAlphaComponent(0.28).cgColor
        )
        stroke(
            roundedPath(rect: rect, radius: radius),
            color: NSColor.black.withAlphaComponent(0.18),
            width: 3.5 * scale,
            in: context
        )
        context.restoreGState()
    }

    private static func drawOuterBloom(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: 20 * scale,
            color: NSColor.white.withAlphaComponent(0.42).cgColor
        )
        stroke(
            roundedPath(rect: rect, radius: radius),
            color: NSColor.white.withAlphaComponent(0.34),
            width: 3.2 * scale,
            in: context
        )
        context.restoreGState()

        let blooms: [(CGFloat, CGFloat)] = [
            (14 * scale, 0.07),
            (9 * scale, 0.10),
            (5.5 * scale, 0.14)
        ]
        for (width, alpha) in blooms {
            stroke(
                roundedPath(rect: rect, radius: radius),
                color: NSColor(calibratedRed: 0.82, green: 0.93, blue: 1.0, alpha: alpha),
                width: width,
                in: context
            )
        }
    }

    private static func drawGlassFill(rect: CGRect, radius: CGFloat, in context: CGContext) {
        context.saveGState()
        context.addPath(roundedPath(rect: rect, radius: radius))
        context.clip()

        let colors = [
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.white.withAlphaComponent(0.07).cgColor,
            NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.0, alpha: 0.05).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.42, 1]
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

    private static func drawLensingRim(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        let path = roundedPath(rect: rect, radius: radius)
        let inner = rect.insetBy(dx: 1.1 * scale, dy: 1.1 * scale)
        let innerRadius = max(2, radius - 1.1 * scale)
        let innerPath = roundedPath(rect: inner, radius: innerRadius)

        stroke(
            roundedPath(rect: rect.insetBy(dx: -1.2 * scale, dy: -1.2 * scale), radius: radius + 1.2 * scale),
            color: NSColor(calibratedRed: 0.55, green: 0.86, blue: 1.0, alpha: 0.28),
            width: 2.2 * scale,
            in: context
        )
        stroke(
            roundedPath(rect: rect.insetBy(dx: 1.0 * scale, dy: 1.0 * scale), radius: max(2, radius - 1.0 * scale)),
            color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.86, alpha: 0.16),
            width: 1.6 * scale,
            in: context
        )

        stroke(path, color: NSColor.white.withAlphaComponent(0.22), width: 8.5 * scale, in: context)
        stroke(path, color: NSColor.white.withAlphaComponent(0.50), width: 4.4 * scale, in: context)
        stroke(path, color: NSColor.white.withAlphaComponent(0.92), width: 1.6 * scale, in: context)
        stroke(innerPath, color: NSColor.white.withAlphaComponent(0.36), width: 1.0 * scale, in: context)
        stroke(innerPath, color: NSColor.black.withAlphaComponent(0.12), width: 0.7 * scale, in: context)
    }

    private static func drawSpecularHighlight(
        rect: CGRect,
        radius: CGFloat,
        scale: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        let highlightBand = CGRect(
            x: rect.minX - 4 * scale,
            y: rect.midY,
            width: rect.width + 8 * scale,
            height: rect.height / 2 + 4 * scale
        )
        context.addRect(highlightBand)
        context.clip()
        stroke(
            roundedPath(rect: rect, radius: radius),
            color: NSColor.white.withAlphaComponent(0.72),
            width: 1.6 * scale,
            in: context
        )
        context.restoreGState()

        context.saveGState()
        let shadowBand = CGRect(
            x: rect.minX - 4 * scale,
            y: rect.minY - 4 * scale,
            width: rect.width + 8 * scale,
            height: rect.height / 2 + 4 * scale
        )
        context.addRect(shadowBand)
        context.clip()
        stroke(
            roundedPath(rect: rect, radius: radius),
            color: NSColor.black.withAlphaComponent(0.16),
            width: 1.4 * scale,
            in: context
        )
        context.restoreGState()
    }

    private static func drawHandles(rect: CGRect, scale: CGFloat, in context: CGContext) {
        let minimum = 36 * scale
        guard rect.width >= minimum, rect.height >= minimum else { return }

        let size = min(20 * scale, max(13 * scale, min(rect.width, rect.height) * 0.13))
        let inset = size * 0.04
        let centers = [
            CGPoint(x: rect.minX + inset, y: rect.minY + inset),
            CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
            CGPoint(x: rect.maxX - inset, y: rect.maxY - inset),
            CGPoint(x: rect.minX + inset, y: rect.maxY - inset)
        ]

        for center in centers {
            drawGlassOrb(at: center, size: size, in: context)
        }
    }

    private static func drawGlassOrb(at center: CGPoint, size: CGFloat, in context: CGContext) {
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1.2),
            blur: size * 0.45,
            color: NSColor.black.withAlphaComponent(0.28).cgColor
        )
        context.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        let colors = [
            NSColor.white.withAlphaComponent(0.78).cgColor,
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor(calibratedRed: 0.72, green: 0.88, blue: 1.0, alpha: 0.16).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.45, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: center.x - size * 0.16, y: center.y + size * 0.18),
                startRadius: 0,
                endCenter: center,
                endRadius: size * 0.62,
                options: [.drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.90).cgColor)
        context.setLineWidth(max(1, size * 0.08))
        context.strokeEllipse(in: rect.insetBy(dx: 0.4, dy: 0.4))

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(max(0.6, size * 0.05))
        context.strokeEllipse(in: rect.insetBy(dx: size * 0.16, dy: size * 0.16))

        let specular = CGRect(
            x: center.x - size * 0.28,
            y: center.y + size * 0.08,
            width: size * 0.28,
            height: size * 0.20
        )
        context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        context.fillEllipse(in: specular)
    }

    private static func drawDimensionBadge(
        _ text: String,
        for rect: CGRect,
        within bounds: CGRect,
        scale: CGFloat,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * max(1, scale * 0.72), weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        let labelSize = (text as NSString).size(withAttributes: attributes)
        let badgeSize = CGSize(width: labelSize.width + 20 * scale, height: labelSize.height + 12 * scale)
        let x = min(max(rect.minX, bounds.minX + 10), bounds.maxX - badgeSize.width - 10)
        let preferredY = rect.maxY + 10 * scale
        let unclampedY = preferredY + badgeSize.height <= bounds.maxY
            ? preferredY
            : rect.maxY - badgeSize.height - 10 * scale
        let y = min(max(unclampedY, bounds.minY + 10), bounds.maxY - badgeSize.height - 10)
        let badgeRect = CGRect(origin: CGPoint(x: x, y: y), size: badgeSize)

        drawGlassCapsule(in: badgeRect, scale: scale, in: context)

        let labelRect = CGRect(
            x: badgeRect.minX + 10 * scale,
            y: badgeRect.minY + 6 * scale,
            width: labelSize.width,
            height: labelSize.height
        )
        (text as NSString).draw(in: labelRect, withAttributes: attributes)
    }

    private static func drawGlassCapsule(in rect: CGRect, scale: CGFloat, in context: CGContext) {
        let radius = min(rect.height / 2, 14 * scale)
        let path = roundedPath(rect: rect, radius: radius)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2 * scale),
            blur: 12 * scale,
            color: NSColor.black.withAlphaComponent(0.30).cgColor
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [
            NSColor.white.withAlphaComponent(0.28).cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor(calibratedWhite: 0.08, alpha: 0.42).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.38, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY),
                options: []
            )
        }
        context.restoreGState()

        stroke(path, color: NSColor.white.withAlphaComponent(0.55), width: 1.0 * scale, in: context)
        stroke(
            roundedPath(rect: rect.insetBy(dx: 1.1 * scale, dy: 1.1 * scale), radius: max(2, radius - 1.1 * scale)),
            color: NSColor.white.withAlphaComponent(0.16),
            width: 0.8 * scale,
            in: context
        )

        context.saveGState()
        context.addRect(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
        context.clip()
        stroke(path, color: NSColor.white.withAlphaComponent(0.42), width: 1.15 * scale, in: context)
        context.restoreGState()
    }
}
