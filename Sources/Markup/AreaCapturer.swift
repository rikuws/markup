import AppKit
import ScreenCaptureKit

/// Captures the pixels for live areas. This is 2.0's inversion of the 1.x
/// pipeline: nothing is captured when the session starts — each area's
/// pixels are read from the screen when the user saves (and once at
/// mouse-up, for OCR dictation context). Markup's own windows are excluded
/// from every capture so the glass panes never appear in the output.
final class AreaCapturer {
    func screenCaptureAccess() -> ScreenCaptureAccess {
        if DeveloperSession.isDebuggerAttached {
            return .blockedByDebugger
        }

        if CGPreflightScreenCaptureAccess() {
            return .granted
        }

        // A successful prompt does not apply to this process. macOS requires a relaunch.
        if CGRequestScreenCaptureAccess() {
            return .needsRelaunch
        }

        return .denied
    }

    /// Captures one area: preferably the whole owning window (so the saved
    /// screenshot has context around the marked spot), falling back to the
    /// window's on-screen bounds cropped from the display, then to the bare
    /// area rect. The returned region locates the area inside the image, in
    /// image pixels with y measured from the top — the same convention 1.x
    /// regions used.
    func capture(area: MarkupArea) -> AreaCapture? {
        if let owner = area.owner {
            if let windowID = owner.windowID,
               let image = captureWindowImage(windowID: windowID) {
                return AreaCapture(
                    area: area,
                    image: image,
                    region: region(of: area.globalRect, within: owner.windowBounds, image: image),
                    source: .ownerWindow
                )
            }

            if let image = captureDisplayRect(owner.windowBounds) {
                return AreaCapture(
                    area: area,
                    image: image,
                    region: region(of: area.globalRect, within: owner.windowBounds, image: image),
                    source: .displayRect
                )
            }
        }

        guard let image = captureDisplayRect(area.globalRect) else {
            return nil
        }

        let cgImage = image.bestCGImage()
        return AreaCapture(
            area: area,
            image: image,
            region: CaptureRegion(x: 0, y: 0, width: cgImage.width, height: cgImage.height),
            source: .areaOnly
        )
    }

    /// One-off capture of just the area's pixels, used at mouse-up for the
    /// OCR dictation bias. The session windows are on screen at that point,
    /// so excluding Markup's application from the filter is what keeps the
    /// glass out of the sample.
    func captureAreaSnapshot(_ globalRect: CGRect) -> NSImage? {
        captureDisplayRect(globalRect)
    }

    private func captureWindowImage(windowID: CGWindowID) -> NSImage? {
        captureScreenshot { content in
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCScreenshotConfiguration()
            configuration.showsCursor = false
            configuration.ignoreShadows = true
            configuration.ignoreClipping = true
            let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            return (filter, configuration)
        }
    }

    /// Captures a global CG rect from the display containing it, with
    /// Markup's own windows excluded so glass panes and chips never land
    /// in the output.
    private func captureDisplayRect(_ globalRect: CGRect) -> NSImage? {
        guard globalRect.width > 0, globalRect.height > 0 else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return captureScreenshot { content in
            guard let display = displayContaining(globalRect, in: content.displays) else {
                return nil
            }

            let markupApps = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: markupApps,
                exceptingWindows: []
            )
            let configuration = SCScreenshotConfiguration()
            configuration.showsCursor = false
            // sourceRect is in the display's own coordinate space (origin at
            // the display's top-left), not global coordinates.
            let local = globalRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.sourceRect = local
            let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
            configuration.width = max(1, Int((globalRect.width * scale).rounded()))
            configuration.height = max(1, Int((globalRect.height * scale).rounded()))
            return (filter, configuration)
        }
    }

    private func captureScreenshot(
        makeRequest: @escaping @Sendable (SCShareableContent) -> (SCContentFilter, SCScreenshotConfiguration)?
    ) -> NSImage? {
        let box = ScreenshotBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let (filter, configuration) = makeRequest(content) else { return }
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                )
                box.image = output.sdrImage
            } catch {
                NSLog("Markup: ScreenCaptureKit screenshot failed: \(error.localizedDescription)")
            }
        }

        _ = semaphore.wait(timeout: .now() + 8)
        guard let cgImage = box.image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Maps the area's global rect into image pixels of a capture that
    /// covers `container` (also global). Clamped so a rect that bleeds past
    /// the window edge still produces a valid region.
    private func region(of globalRect: CGRect, within container: CGRect, image: NSImage) -> CaptureRegion {
        let cgImage = image.bestCGImage()
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        guard container.width > 0, container.height > 0 else {
            return CaptureRegion(x: 0, y: 0, width: Int(pixelWidth), height: Int(pixelHeight))
        }

        let scaleX = pixelWidth / container.width
        let scaleY = pixelHeight / container.height
        let clipped = globalRect.intersection(container)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return CaptureRegion(x: 0, y: 0, width: Int(pixelWidth), height: Int(pixelHeight))
        }

        // Both spaces have y growing downward (CG global, image top-left),
        // so no flip is needed — only translation and scale.
        let x = (clipped.minX - container.minX) * scaleX
        let y = (clipped.minY - container.minY) * scaleY
        let width = clipped.width * scaleX
        let height = clipped.height * scaleY

        return CaptureRegion(
            x: max(0, min(Int(x.rounded()), Int(pixelWidth) - 1)),
            y: max(0, min(Int(y.rounded()), Int(pixelHeight) - 1)),
            width: max(1, min(Int(width.rounded()), Int(pixelWidth))),
            height: max(1, min(Int(height.rounded()), Int(pixelHeight)))
        )
    }
}

private func displayContaining(_ bounds: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    if let exact = displays.first(where: { $0.frame.contains(center) }) {
        return exact
    }

    return displays.max { lhs, rhs in
        let left = lhs.frame.intersection(bounds)
        let right = rhs.frame.intersection(bounds)
        let leftArea = left.isNull || left.isEmpty ? 0 : left.width * left.height
        let rightArea = right.isNull || right.isEmpty ? 0 : right.width * right.height
        return leftArea < rightArea
    }
}

private final class ScreenshotBox: @unchecked Sendable {
    var image: CGImage?
}
