import AppKit
import ApplicationServices

final class ActiveWindowCapturer {
    func captureActiveWindow() -> CapturedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? "Unknown App"
        let bundleId = app.bundleIdentifier ?? "unknown.bundle"
        let focusedWindow = focusedAXWindow(for: pid)
        let cgWindow = frontmostCGWindow(for: pid, focusedWindow: focusedWindow)
        let title = firstNonEmpty(focusedWindow?.title, cgWindow?.title, appName)

        guard let cgWindow else {
            NSLog("Markup: no capturable window found for \(appName) pid=\(pid)")
            return nil
        }

        let routeTarget = RouteTargetResolver.target(for: app, windowTitle: title)

        NSLog("Markup: capturing window \(cgWindow.id) title='\(cgWindow.title ?? "")' bounds=\(NSStringFromRect(cgWindow.bounds)) for \(appName)")

        guard let image = captureWindowImage(windowID: cgWindow.id)
            ?? captureVisibleWindowRegion(bounds: cgWindow.bounds)
        else {
            NSLog("Markup: failed to capture window \(cgWindow.id) for \(appName)")
            return nil
        }

        return CapturedWindow(
            image: image,
            appName: appName,
            bundleId: bundleId,
            windowTitle: title,
            processIdentifier: pid,
            windowID: cgWindow.id,
            screenFrame: screenFrame(for: cgWindow.bounds),
            browserPage: routeTarget.browserPage
        )
    }

    func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        return CGRequestScreenCaptureAccess()
    }

    private func captureWindowImage(windowID: CGWindowID) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func captureVisibleWindowRegion(bounds: CGRect) -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let cgImage = CGWindowListCreateImage(
                bounds,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
              )
        else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func screenFrame(for windowBounds: CGRect) -> NSRect {
        let fallback = NSScreen.main?.frame
            ?? NSScreen.screens.first?.frame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let screens = NSScreen.screens.compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
            guard let displayID = screen.displayID else { return nil }
            return (screen, CGDisplayBounds(displayID))
        }
        guard !screens.isEmpty else { return fallback }

        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        if let match = screens.first(where: { $0.bounds.contains(center) }) {
            return match.screen.frame
        }

        let ranked = screens.map { candidate in
            (screen: candidate.screen, area: intersectionArea(windowBounds, candidate.bounds))
        }
        guard let match = ranked.max(by: { $0.area < $1.area }), match.area > 0 else {
            return fallback
        }

        return match.screen.frame
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private func frontmostCGWindow(
        for pid: pid_t,
        focusedWindow: FocusedAXWindow?
    ) -> WindowCandidate? {
        let candidates = windowCandidates(for: pid)
        guard !candidates.isEmpty else { return nil }

        if let focusedFrame = focusedWindow?.frame,
           let match = bestFrameMatch(for: focusedFrame, in: candidates) {
            return match
        }

        if let focusedTitle = focusedWindow?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !focusedTitle.isEmpty,
           let match = candidates.first(where: { $0.title == focusedTitle }) {
            return match
        }

        return candidates.first
    }

    private func windowCandidates(for pid: pid_t) -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item in
            guard let ownerPID = item[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = item[kCGWindowNumber as String] as? UInt32,
                  let bounds = windowBounds(from: item)
            else { return nil }

            if let alpha = item[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                return nil
            }

            if let sharingState = item[kCGWindowSharingState as String] as? Int, sharingState == 0 {
                return nil
            }

            guard bounds.width > 48, bounds.height > 48 else { return nil }

            return WindowCandidate(
                id: CGWindowID(windowNumber),
                title: item[kCGWindowName as String] as? String,
                bounds: bounds
            )
        }
    }

    private func windowBounds(from item: [String: Any]) -> CGRect? {
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

    private func focusedAXWindow(for pid: pid_t) -> FocusedAXWindow? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow
        else {
            return nil
        }

        let window = focusedWindow as! AXUIElement
        var title: CFTypeRef?
        let windowTitle = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
            ? title as? String
            : nil

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let frame: CGRect?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let positionRef,
           let sizeRef {
            let positionValue = positionRef as! AXValue
            let sizeValue = sizeRef as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            let hasPosition = AXValueGetValue(positionValue, .cgPoint, &position)
            let hasSize = AXValueGetValue(sizeValue, .cgSize, &size)
            frame = hasPosition && hasSize ? CGRect(origin: position, size: size) : nil
        } else {
            frame = nil
        }

        return FocusedAXWindow(title: windowTitle, frame: frame)
    }

    private func bestFrameMatch(
        for focusedFrame: CGRect,
        in candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        let scored = candidates.map { candidate in
            (
                candidate: candidate,
                score: abs(candidate.bounds.minX - focusedFrame.minX)
                    + abs(candidate.bounds.minY - focusedFrame.minY)
                    + abs(candidate.bounds.width - focusedFrame.width)
                    + abs(candidate.bounds.height - focusedFrame.height)
            )
        }

        guard let best = scored.min(by: { $0.score < $1.score }),
              best.score <= 96
        else {
            return nil
        }

        return best.candidate
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Untitled Window"
    }
}

private struct FocusedAXWindow {
    var title: String?
    var frame: CGRect?
}

private struct WindowCandidate {
    var id: CGWindowID
    var title: String?
    var bounds: CGRect
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }
}
