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
    /// Finds the window owning the majority of `globalRect` (CG coordinates).
    /// Samples the center plus inset corners; each sample votes for the
    /// frontmost normal-layer window under it, skipping Markup's own
    /// session windows. Returns nil when the area sits on the bare desktop.
    static func owningWindow(under globalRect: CGRect) -> ResolvedAreaWindow? {
        let candidates = onScreenWindows()
        guard !candidates.isEmpty else { return nil }

        let inset = min(8, globalRect.width / 4, globalRect.height / 4)
        let sampled = globalRect.insetBy(dx: inset, dy: inset)
        let samples = [
            CGPoint(x: globalRect.midX, y: globalRect.midY),
            CGPoint(x: sampled.minX, y: sampled.minY),
            CGPoint(x: sampled.maxX, y: sampled.minY),
            CGPoint(x: sampled.minX, y: sampled.maxY),
            CGPoint(x: sampled.maxX, y: sampled.maxY)
        ]

        var votes: [CGWindowID: Int] = [:]
        for point in samples {
            // The window list is front-to-back; the first hit is the
            // visible window at this point.
            guard let hit = candidates.first(where: { $0.bounds.contains(point) }) else {
                continue
            }
            votes[hit.windowID, default: 0] += 1
        }

        guard let winner = votes.max(by: { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : orderIndex(of: lhs.key, in: candidates) > orderIndex(of: rhs.key, in: candidates)
        }) else {
            return nil
        }

        return candidates.first { $0.windowID == winner.key }
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

    private static func orderIndex(of windowID: CGWindowID, in candidates: [ResolvedAreaWindow]) -> Int {
        candidates.firstIndex { $0.windowID == windowID } ?? candidates.count
    }

    /// Normal-layer on-screen windows, front-to-back, excluding Markup's
    /// own process (the transparent session windows would otherwise win
    /// every hit test).
    private static func onScreenWindows() -> [ResolvedAreaWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { item in
            guard let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = windowBounds(from: item)
            else { return nil }

            if let alpha = item[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return nil
            }

            guard bounds.width > 24, bounds.height > 24 else { return nil }

            let app = NSRunningApplication(processIdentifier: ownerPID)
            return ResolvedAreaWindow(
                appName: (item[kCGWindowOwnerName as String] as? String)
                    ?? app?.localizedName
                    ?? "Unknown App",
                bundleId: app?.bundleIdentifier ?? "unknown.bundle",
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
}
