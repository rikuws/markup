import AppKit
import Foundation

final class FeedbackBundleWriter {
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    }

    func write(draft: FeedbackDraft, route: AppRoute) throws -> URL {
        guard let primaryShot = draft.shots.first else {
            throw MarkupError("Feedback needs at least one screenshot.")
        }

        let now = Date()
        let id = makeID(date: now, appName: primaryShot.captured.routeName)
        let directory = route.feedbackDirectoryURL.appendingPathComponent(id, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var captures: [FeedbackMetadata.CaptureItemMetadata] = []
        for (offset, shot) in draft.shots.enumerated() {
            let index = offset + 1
            if draft.requiresRegions, shot.region == nil {
                throw MarkupError("Shot \(index) needs a highlighted region.")
            }

            let region = shot.region
            let screenshotImage: NSImage
            if let region {
                guard let annotatedImage = ScreenshotAnnotator.annotatedImage(source: shot.captured.image, region: region) else {
                    throw MarkupError("Could not annotate shot \(index).")
                }
                screenshotImage = annotatedImage
            } else {
                screenshotImage = shot.captured.image
            }

            let annotatedName = FeedbackAssetNames.annotatedScreenshot(for: index)
            let originalName = FeedbackAssetNames.originalScreenshot(for: index)
            try screenshotImage.writePNG(to: directory.appendingPathComponent(annotatedName))
            try shot.captured.image.writePNG(to: directory.appendingPathComponent(originalName))

            let image = shot.captured.image.bestCGImage()
            let capture = FeedbackMetadata.CaptureMetadata(
                type: shot.captured.windowID == nil ? "mainDisplayFallback" : "activeWindow",
                screenshotSize: .init(width: image.width, height: image.height),
                region: region
            )
            captures.append(
                .init(
                    index: index,
                    label: shot.trimmedLabel,
                    app: .init(
                        bundleId: shot.captured.bundleId,
                        name: shot.captured.appName,
                        windowTitle: shot.captured.windowTitle
                    ),
                    browser: shot.captured.browserPage,
                    capture: capture,
                    assets: .init(
                        annotatedScreenshot: annotatedName,
                        originalScreenshot: originalName
                    )
                )
            )
        }

        var copiedRecording: String?
        if let recordingURL = draft.recordingURL {
            let destination = directory.appendingPathComponent(FeedbackAssetNames.recording)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: recordingURL, to: destination)
            copiedRecording = FeedbackAssetNames.recording
        }

        guard let primaryCapture = captures.first else {
            throw MarkupError("Feedback needs at least one screenshot.")
        }

        let metadata = FeedbackMetadata(
            id: id,
            schemaVersion: 3,
            createdAt: isoFormatter.string(from: now),
            app: primaryCapture.app,
            browser: primaryCapture.browser,
            project: .init(
                root: route.projectRoot,
                feedbackPath: route.feedbackPath
            ),
            capture: primaryCapture.capture,
            assets: .init(
                annotatedScreenshot: primaryCapture.assets.annotatedScreenshot,
                originalScreenshot: primaryCapture.assets.originalScreenshot,
                recording: copiedRecording
            ),
            captures: captures
        )

        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: directory.appendingPathComponent(FeedbackAssetNames.metadata), options: .atomic)

        let instruction = instructionMarkdown(
            draft: draft,
            metadata: metadata,
            hasRecording: copiedRecording != nil
        )
        try instruction.write(
            to: directory.appendingPathComponent(FeedbackAssetNames.instruction),
            atomically: true,
            encoding: .utf8
        )

        return directory
    }

    private func makeID(date: Date, appName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: date)
        let slug = appName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(timestamp)-\(slug.isEmpty ? "app" : slug)-\(suffix)"
    }

    private func instructionMarkdown(
        draft: FeedbackDraft,
        metadata: FeedbackMetadata,
        hasRecording: Bool
    ) -> String {
        let captured = draft.primaryCapture
        let hasHighlightedRegion = metadata.captures.contains { $0.capture.region != nil }
        let screenshotIntro = screenshotIntroMarkdown(
            captureCount: metadata.captures.count,
            hasRecording: hasRecording
        )
        let regionGuidance = regionGuidanceMarkdown(
            hasRecording: hasRecording,
            hasHighlightedRegion: hasHighlightedRegion
        )
        let doneWhenRegionLine = hasHighlightedRegion
            ? "- The highlighted UI regions no longer exhibit the problem."
            : "- The behavior shown in the recording and screenshots no longer exhibits the problem."

        return """
        # Visual Feedback: \(captured.windowTitle)

        \(screenshotIntro)

        User note:
        > \(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n> "))

        Screenshots:
        \(screenshotsMarkdown(metadata.captures))

        \(regionGuidance) `capture` and `assets` also describe Shot 1 for compatibility.

        Context:
        - Captured app: \(captured.appName)
        - Bundle ID: \(captured.bundleId)
        - Window title: \(captured.windowTitle)
        \(browserContextMarkdown(captured.browserPage))
        - Captured at: \(metadata.createdAt)
        - Optional recording: \(hasRecording ? "`\(FeedbackAssetNames.recording)`" : "not attached")

        Done when:
        - The issue described in the note is addressed.
        \(doneWhenRegionLine)
        """
    }

    private func screenshotIntroMarkdown(
        captureCount: Int,
        hasRecording: Bool
    ) -> String {
        if hasRecording {
            return captureCount == 1
                ? "Improve the UI/UX/code issue shown in `\(FeedbackAssetNames.annotatedScreenshot)` and `\(FeedbackAssetNames.recording)`."
                : "Improve the UI/UX/code issue shown across the screenshots and `\(FeedbackAssetNames.recording)` in this bundle."
        }

        return captureCount == 1
            ? "Improve the UI/UX/code issue shown in `\(FeedbackAssetNames.annotatedScreenshot)`."
            : "Improve the UI/UX/code issue shown across the screenshots in this bundle."
    }

    private func regionGuidanceMarkdown(hasRecording: Bool, hasHighlightedRegion: Bool) -> String {
        if hasHighlightedRegion {
            return "Highlighted regions are stored as x/y/width/height values in `\(FeedbackAssetNames.metadata)` under `captures[n].capture.region`."
        }

        if hasRecording {
            return "No highlighted region was selected; use the recording and screenshots as the feedback target."
        }

        return "No highlighted region was selected."
    }

    private func screenshotsMarkdown(_ captures: [FeedbackMetadata.CaptureItemMetadata]) -> String {
        captures.map { capture in
            var line = "- Shot \(capture.index): `\(capture.assets.annotatedScreenshot)`"
            if let label = capture.label {
                line += " - \(label)"
            }
            if capture.capture.region != nil {
                line += " (region: `captures[\(capture.index - 1)].capture.region`)"
            } else {
                line += " (no marked region)"
            }
            return line
        }
        .joined(separator: "\n")
    }

    private func browserContextMarkdown(_ browserPage: BrowserPageContext?) -> String {
        guard let browserPage else { return "" }

        var lines = [
            "- Browser route: \(browserPage.routeName)",
            "- Browser title: \(browserPage.title)"
        ]

        if let url = browserPage.url {
            lines.append("- Browser URL: \(url)")
        }

        return lines.joined(separator: "\n")
    }
}

private extension FeedbackDraftShot {
    var trimmedLabel: String? {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension NSImage {
    func writePNG(to url: URL) throws {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw MarkupError("Could not encode PNG image.")
        }

        try data.write(to: url, options: .atomic)
    }
}

struct MarkupError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
