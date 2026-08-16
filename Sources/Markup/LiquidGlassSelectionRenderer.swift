import AppKit

/// Paints a flattened approximation of the Liquid Glass selection pane
/// into exported screenshots. The live UI uses a real `NSGlassEffectView`;
/// system glass cannot be composited into an offscreen bitmap, so exports
/// get the same read — a clear slab whose edges fog and catch light.
enum LiquidGlassSelectionRenderer {
    static func drawPane(rect: CGRect, in context: CGContext, scale: CGFloat = 1) {
        guard rect.width > 1, rect.height > 1 else { return }

        let radius = min(28 * scale, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        drawContactShadow(path: path, scale: scale, in: context)
        drawEdgeFog(rect: rect, path: path, scale: scale, in: context)
        drawRim(rect: rect, path: path, scale: scale, in: context)

        context.restoreGState()
    }

    /// Soft shadow just outside the pane so it reads as floating glass.
    private static func drawContactShadow(path: CGPath, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2 * scale),
            blur: 10 * scale,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1.5 * scale)
        context.strokePath()
        context.restoreGState()
    }

    /// The milky band that hugs the inside of the edge while the center
    /// stays clear — the defining look of the glass slab.
    private static func drawEdgeFog(rect: CGRect, path: CGPath, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        context.addPath(path)
        context.clip()

        let bands: [(width: CGFloat, alpha: CGFloat)] = [
            (44 * scale, 0.07),
            (26 * scale, 0.10),
            (14 * scale, 0.13),
            (7 * scale, 0.16)
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
    /// glass catches light along its silhouette.
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
