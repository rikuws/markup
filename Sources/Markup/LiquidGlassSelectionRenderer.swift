import AppKit

/// Draws the area-selection chrome as a quiet glass layer: a hairline
/// rim, a faint sheet of light, and iOS-screenshot-style handles.
/// Separation comes from a soft shadow and a bright edge, not from
/// glows or accent colors.
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
        min(3 * scale, min(rect.width, rect.height) / 2)
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

        stroke(path, color: NSColor.white.withAlphaComponent(0.92), width: 1.25 * scale, in: context)
    }

    /// iOS screenshot crop handles: thick white L-brackets at the corners
    /// and short bars at the midpoint of each side, sitting on the hairline.
    private static func drawHandles(rect: CGRect, scale: CGFloat, in context: CGContext) {
        let thickness = 5.5 * scale
        let length = min(24 * scale, max(16 * scale, min(rect.width, rect.height) * 0.18))
        let outerRadius = min(2.4 * scale, thickness * 0.45)
        let minimum = length * 2 + thickness * 2
        guard rect.width >= minimum, rect.height >= minimum else { return }

        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.setShadow(
            offset: CGSize(width: 0, height: -0.6 * scale),
            blur: 2.4 * scale,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )

        addCornerHandle(to: context, at: .bottomLeft, rect: rect, length: length, thickness: thickness, outerRadius: outerRadius)
        addCornerHandle(to: context, at: .bottomRight, rect: rect, length: length, thickness: thickness, outerRadius: outerRadius)
        addCornerHandle(to: context, at: .topRight, rect: rect, length: length, thickness: thickness, outerRadius: outerRadius)
        addCornerHandle(to: context, at: .topLeft, rect: rect, length: length, thickness: thickness, outerRadius: outerRadius)

        let midGap = length * 2.4
        if rect.width >= midGap {
            addEdgeHandle(to: context, at: .top, rect: rect, length: length, thickness: thickness)
            addEdgeHandle(to: context, at: .bottom, rect: rect, length: length, thickness: thickness)
        }
        if rect.height >= midGap {
            addEdgeHandle(to: context, at: .left, rect: rect, length: length, thickness: thickness)
            addEdgeHandle(to: context, at: .right, rect: rect, length: length, thickness: thickness)
        }

        context.restoreGState()
    }

    private enum Corner {
        case bottomLeft, bottomRight, topRight, topLeft
    }

    private enum Edge {
        case top, bottom, left, right
    }

    private static func addCornerHandle(
        to context: CGContext,
        at corner: Corner,
        rect: CGRect,
        length: CGFloat,
        thickness: CGFloat,
        outerRadius: CGFloat
    ) {
        let half = thickness / 2
        let path = CGMutablePath()

        switch corner {
        case .bottomLeft:
            addLPath(
                path,
                outer: CGPoint(x: rect.minX, y: rect.minY),
                alongX: 1,
                alongY: 1,
                length: length,
                half: half,
                outerRadius: outerRadius
            )
        case .bottomRight:
            addLPath(
                path,
                outer: CGPoint(x: rect.maxX, y: rect.minY),
                alongX: -1,
                alongY: 1,
                length: length,
                half: half,
                outerRadius: outerRadius
            )
        case .topRight:
            addLPath(
                path,
                outer: CGPoint(x: rect.maxX, y: rect.maxY),
                alongX: -1,
                alongY: -1,
                length: length,
                half: half,
                outerRadius: outerRadius
            )
        case .topLeft:
            addLPath(
                path,
                outer: CGPoint(x: rect.minX, y: rect.maxY),
                alongX: 1,
                alongY: -1,
                length: length,
                half: half,
                outerRadius: outerRadius
            )
        }

        context.addPath(path)
        context.fillPath()
    }

    /// Builds a filled L whose outer corner is rounded and whose inner
    /// corner stays a sharp 90°. `alongX` / `alongY` are +1 or -1 and
    /// point from the outer corner along each arm.
    private static func addLPath(
        _ path: CGMutablePath,
        outer: CGPoint,
        alongX: CGFloat,
        alongY: CGFloat,
        length: CGFloat,
        half: CGFloat,
        outerRadius: CGFloat
    ) {
        let nx = -alongX
        let ny = -alongY
        let r = min(outerRadius, half)

        let outerOut = CGPoint(x: outer.x + nx * half, y: outer.y + ny * half)
        let verticalEnd = CGPoint(x: outer.x, y: outer.y + alongY * length)
        let horizontalEnd = CGPoint(x: outer.x + alongX * length, y: outer.y)

        path.move(to: CGPoint(x: verticalEnd.x + nx * half, y: verticalEnd.y))
        path.addLine(to: CGPoint(x: verticalEnd.x + alongX * half, y: verticalEnd.y))
        path.addLine(to: CGPoint(x: outer.x + alongX * half, y: outer.y + alongY * half))
        path.addLine(to: CGPoint(x: horizontalEnd.x, y: horizontalEnd.y + alongY * half))
        path.addLine(to: CGPoint(x: horizontalEnd.x, y: horizontalEnd.y + ny * half))
        path.addLine(to: CGPoint(x: outerOut.x + alongX * r, y: outerOut.y))
        path.addQuadCurve(
            to: CGPoint(x: outerOut.x, y: outerOut.y + alongY * r),
            control: outerOut
        )
        path.closeSubpath()
    }

    private static func addEdgeHandle(
        to context: CGContext,
        at edge: Edge,
        rect: CGRect,
        length: CGFloat,
        thickness: CGFloat
    ) {
        let handle: CGRect
        switch edge {
        case .top:
            handle = CGRect(x: rect.midX - length / 2, y: rect.maxY - thickness / 2, width: length, height: thickness)
        case .bottom:
            handle = CGRect(x: rect.midX - length / 2, y: rect.minY - thickness / 2, width: length, height: thickness)
        case .left:
            handle = CGRect(x: rect.minX - thickness / 2, y: rect.midY - length / 2, width: thickness, height: length)
        case .right:
            handle = CGRect(x: rect.maxX - thickness / 2, y: rect.midY - length / 2, width: thickness, height: length)
        }

        context.addPath(CGPath(rect: handle, transform: nil))
        context.fillPath()
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
