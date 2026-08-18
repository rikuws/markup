import AppKit
import Foundation

/// The window a live area was drawn over, found by geometry instead of
/// focus. 1.x routed by the frontmost application; in a live session the
/// frontmost app is Markup itself and different areas can sit on different
/// apps, so ownership is decided per area by hit-testing the on-screen
/// window list.
struct ResolvedAreaWindow {
    var appName: String
    var bundleId: String
    var windowTitle: String
    var processIdentifier: pid_t
    var windowID: CGWindowID
    /// Global CG coordinates.
    var bounds: CGRect
}

enum AreaWindowResolver {
    /// Finds the window the user was pointing at while drawing `globalRect`
    /// (CG coordinates).
    ///
    /// Hit-tests the drag origin (or the rect center) against the on-screen
    /// list in front-to-back order. A majority vote over the rect's corners
    /// would pick a large window *behind* a smaller one whenever the
    /// selection spilled past the front window — or whenever a browser
    /// overlay covered the same points.
    ///
    /// `preferringProcessID` is the app that was frontmost when the session
    /// started. Chromium/Dia keep large untitled shields in front of other
    /// apps; when that shield is listed above the origin app's real window,
    /// the origin app wins.
    static func owningWindow(
        under globalRect: CGRect,
        probe: CGPoint? = nil,
        preferringProcessID: pid_t? = nil
    ) -> ResolvedAreaWindow? {
        let candidates = onScreenWindows()
        guard !candidates.isEmpty else { return nil }

        let point = clamp(probe ?? CGPoint(x: globalRect.midX, y: globalRect.midY), to: globalRect)
        let hits = candidates.filter { $0.bounds.contains(point) }
        if let hit = pickHit(from: hits, preferringProcessID: preferringProcessID) {
            return hit
        }

        return largestOverlap(under: globalRect, in: candidates)
    }

    static func owner(for window: ResolvedAreaWindow) -> AreaOwner {
        let app = NSRunningApplication(processIdentifier: window.processIdentifier)
        let appName = app?.localizedName ?? window.appName
        let title = window.windowTitle.isEmpty ? appName : window.windowTitle

        var browserPage: BrowserPageContext?
        if let app {
            browserPage = BrowserPageContextResolver.context(
                for: app,
                appName: appName,
                bundleId: window.bundleId,
                windowTitle: title
            )
        }

        NSLog(
            "Markup: area owner \(appName) pid=\(window.processIdentifier) title='\(window.windowTitle)' bounds=\(NSStringFromRect(window.bounds))"
        )

        return AreaOwner(
            appName: appName,
            bundleId: window.bundleId,
            windowTitle: title,
            processIdentifier: window.processIdentifier,
            windowID: window.windowID,
            windowBounds: window.bounds,
            browserPage: browserPage
        )
    }

    /// Frontmost plausible window at the probe. Untitled full-display
    /// shields are skipped so a browser overlay cannot steal the app
    /// underneath. If a remaining larger window fully covers the session's
    /// origin app, that origin window is the one the user can actually see.
    private static func pickHit(
        from hits: [ResolvedAreaWindow],
        preferringProcessID: pid_t?
    ) -> ResolvedAreaWindow? {
        let displays = ScreenGeometry.displayBounds()
        let contentHits = hits.filter { !isShield($0, displays: displays) }
        let ordered = contentHits.isEmpty ? hits : contentHits
        guard let front = ordered.first else { return nil }

        guard let preferringProcessID,
              preferringProcessID != front.processIdentifier,
              let preferred = ordered.first(where: { $0.processIdentifier == preferringProcessID })
        else {
            return front
        }

        if front.bounds.insetBy(dx: -2, dy: -2).contains(preferred.bounds) {
            return preferred
        }

        return front
    }

    private static func largestOverlap(
        under rect: CGRect,
        in candidates: [ResolvedAreaWindow]
    ) -> ResolvedAreaWindow? {
        let ranked = candidates.compactMap { window -> (ResolvedAreaWindow, CGFloat)? in
            let area = intersectionArea(window.bounds, rect)
            guard area > 0 else { return nil }
            return (window, area)
        }
        return ranked.max { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : false
        }?.0
    }

    /// Untitled surfaces that cover a whole display — typical of Chromium
    /// click-through overlays, not the UI the user is marking.
    private static func isShield(_ window: ResolvedAreaWindow, displays: [CGRect]) -> Bool {
        guard window.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return displays.contains { display in
            let displayArea = display.width * display.height
            guard displayArea > 0 else { return false }
            let covered = intersectionArea(window.bounds, display)
            return covered / displayArea >= 0.95
        }
    }

    private static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    /// On-screen windows, front-to-back, excluding Markup, the desktop,
    /// system chrome, and fully transparent surfaces. Includes floating
    /// and utility panels — those are often the window the user marked
    /// on top of a browser.
    private static func onScreenWindows() -> [ResolvedAreaWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let maxLayer = Int(CGWindowLevelForKey(.draggingWindow))

        return list.compactMap { item in
            guard let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  layer >= 0,
                  layer < maxLayer,
                  let windowNumber = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = windowBounds(from: item)
            else { return nil }

            if let alpha = item[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
                return nil
            }

            guard bounds.width > 24, bounds.height > 24 else { return nil }

            let app = NSRunningApplication(processIdentifier: ownerPID)
            let appName = (item[kCGWindowOwnerName as String] as? String)
                ?? app?.localizedName
                ?? "Unknown App"
            let bundleId = app?.bundleIdentifier ?? "unknown.bundle"

            guard !ignoredOwnerNames.contains(appName),
                  !ignoredBundleIds.contains(bundleId)
            else { return nil }

            return ResolvedAreaWindow(
                appName: appName,
                bundleId: bundleId,
                windowTitle: (item[kCGWindowName as String] as? String) ?? "",
                processIdentifier: ownerPID,
                windowID: CGWindowID(windowNumber),
                bounds: bounds
            )
        }
    }

    private static func windowBounds(from item: [String: Any]) -> CGRect? {
        guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double,
              let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double,
              let height = bounds["Height"] as? Double
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static let ignoredOwnerNames: Set<String> = [
        "Window Server",
        "WindowManager",
        "Dock",
        "Control Center",
        "Control Centre",
        "Notification Center",
        "Notification Centre",
        "SystemUIServer",
        "Spotlight",
        "loginwindow",
        "Wallpaper",
        "Backstop Menus",
        "CursorUIViewService",
        "Screenshot",
        "screencaptureui"
    ]

    private static let ignoredBundleIds: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.NotificationCenter",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.wallpaper.agent",
        "com.apple.screenshot.launcher",
        "com.apple.screencaptureui"
    ]
}
