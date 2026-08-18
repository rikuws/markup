import AppKit

/// Bridges the two global coordinate spaces the live session straddles:
/// Cocoa (NSScreen/NSWindow, origin bottom-left of the primary display,
/// y up) and CG (CGWindowList/ScreenCaptureKit, origin top-left of the
/// primary display, y down). Both share the x axis; y flips around the
/// primary display's height.
enum ScreenGeometry {
    /// The primary display (the one carrying the menu bar) has Cocoa origin
    /// (0, 0), so its frame height is the flip line for the whole desktop.
    /// Use the Core Graphics main-display height, not `NSScreen.screens.first`:
    /// that array is keyed by the current key window, which during a session
    /// is Markup's overlay and may be a secondary display.
    static var primaryScreenHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Each attached display in CG coordinates (origin top-left of the
    /// primary display), matching `CGWindowList` bounds.
    static func displayBounds() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
    }

    static func cgRect(fromCocoa rect: NSRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaRect(fromCG rect: CGRect) -> NSRect {
        NSRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cgPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// The screen whose frame contains the rect's center, else the screen
    /// with the largest overlap. Rects are in Cocoa coordinates.
    static func screen(containingCocoa rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return exact
        }

        return NSScreen.screens.max { lhs, rhs in
            overlapArea(lhs.frame, rect) < overlapArea(rhs.frame, rect)
        }
    }

    private static func overlapArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
