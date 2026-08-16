import AppKit

/// Paints a flattened approximation of the Liquid Glass selection pane
/// into exported screenshots. The live UI uses a filled `.clear` glass
/// rounded rect whose rim melts into the interior; system glass cannot
/// be composited into an offscreen bitmap, so exports get the same read —
/// a soft glass wash, stronger at the edges, with a light-catching outer
/// rim and no inner bevel.
enum LiquidGlassSelectionRenderer {
    static func drawPane(rect: CGRect, in context: CGContext, scale: CGFloat = 1) {
        guard rect.width > 1, rect.height > 1 else { return }

        let radius = min(28 * scale, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        drawContactShadow(path: path, scale: scale, in: context)
        drawMelt(rect: rect, path: path, scale: scale, in: context)
        drawRim(rect: rect, path: path, scale: scale, in: context)

        context.restoreGState()
    }

    /// Soft shadow just outside the pane so it reads as floating glass.
    private static func drawContactShadow(path: CGPath, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2 * scale),
            blur: 8 * scale,
            color: NSColor.black.withAlphaComponent(0.10).cgColor
        )
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1.5 * scale)
        context.strokePath()
        context.restoreGState()
    }

    /// Glass color across the pane, denser at the rim and easing into the
    /// center — the look of `.clear` Liquid Glass melting inward rather
    /// than a punched-out band with an inner bevel.
    private static func drawMelt(rect: CGRect, path: CGPath, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.clip()

        context.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
        context.fill(rect)
        context.setFillColor(NSColor.black.withAlphaComponent(0.02).cgColor)
        context.fill(rect)

        let shortest = min(rect.width, rect.height)
        let melt = min(shortest * 0.48, 100 * scale)
        let bands: [(width: CGFloat, alpha: CGFloat)] = [
            (melt * 1.7, 0.03),
            (melt * 1.15, 0.045),
            (melt * 0.72, 0.06),
            (melt * 0.4, 0.08),
            (melt * 0.18, 0.10),
            (4 * scale, 0.08)
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
