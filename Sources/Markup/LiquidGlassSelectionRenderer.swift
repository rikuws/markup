import AppKit

/// Paints a flattened approximation of the Liquid Glass selection pane
/// into exported screenshots. The live UI uses `.clear` glass on a filled
/// rounded rect, masked so a thin rim stays denser while a faint wash
/// keeps the interior connected to the edge. System glass cannot be
/// composited into an offscreen bitmap, so exports get the same read —
/// a short edge wash, a hairline rim, and a slight center tint.
enum LiquidGlassSelectionRenderer {
    /// Outer corner radius. Liquid Glass bevels track this, so it stays
    /// small — a tight silhouette rather than a chunky glass slab.
    static let cornerRadiusMax: CGFloat = 8

    /// Rim depth as a fraction of the pane's shortest side. Kept tight so
    /// the glass edge is a fine bevel, not a hollow frame.
    static let meltFraction: CGFloat = 0.04
    static let meltMin: CGFloat = 2.5
    static let meltMax: CGFloat = 7

    /// Remaining live-glass visibility in the punched interior, so the
    /// pane is one sheet instead of a rim around a hole.
    static let centerGlass: CGFloat = 0.12

    /// Slight white wash across the whole pane — enough to read as glass,
    /// not enough to hide the screenshot.
    static let centerFill: CGFloat = 0.04

    static func cornerRadius(shortest: CGFloat, scale: CGFloat = 1) -> CGFloat {
        min(cornerRadiusMax * scale, shortest / 2)
    }

    static func meltDepth(shortest: CGFloat, scale: CGFloat = 1) -> CGFloat {
        max(meltMin * scale, min(shortest * meltFraction, meltMax * scale))
    }

    static func drawPane(rect: CGRect, in context: CGContext, scale: CGFloat = 1) {
        guard rect.width > 1, rect.height > 1 else { return }

        let radius = cornerRadius(shortest: min(rect.width, rect.height), scale: scale)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        drawMelt(rect: rect, path: path, scale: scale, in: context)
        drawRim(rect: rect, path: path, scale: scale, in: context)

        context.restoreGState()
    }

    /// Glass color packed against a thin rim, with a faint wash so the
    /// interior stays tied to the edge. Strokes are clipped to the pane —
    /// nothing blooms outside as a glow.
    private static func drawMelt(rect: CGRect, path: CGPath, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.clip()

        context.setFillColor(NSColor.white.withAlphaComponent(centerFill).cgColor)
        context.fill(rect)

        let shortest = min(rect.width, rect.height)
        let melt = meltDepth(shortest: shortest, scale: scale)
        // Line widths are centered on the path; clipping leaves half of
        // each stroke as the inward wash. `melt * 2` therefore reaches
        // about `melt` into the pane, then the tighter bands steepen
        // the falloff into the faint center wash.
        let bands: [(width: CGFloat, alpha: CGFloat)] = [
            (melt * 2.0, 0.035),
            (melt * 1.0, 0.05),
            (melt * 0.4, 0.07),
            (2.0 * scale, 0.09)
        ]
        for band in bands {
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(band.alpha).cgColor)
            context.setLineWidth(band.width)
            context.strokePath()
        }

        context.restoreGState()
    }

    /// Hairline rim with a slightly brighter top edge, imitating how the
    /// glass catches light along its outer silhouette.
    private static func drawRim(rect: CGRect, path: CGPath, scale: CGFloat, in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1.2 * scale)
        context.addPath(path)
        context.strokePath()

        context.saveGState()
        context.addRect(
            CGRect(
                x: rect.minX - 2 * scale,
                y: rect.midY,
                width: rect.width + 4 * scale,
                height: rect.height / 2 + 2 * scale
            )
        )
        context.clip()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.2 * scale)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}
