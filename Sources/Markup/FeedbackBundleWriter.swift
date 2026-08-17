import AppKit
import Foundation

/// Writes one feedback bundle per route from a live session's captured
/// areas. The on-disk shape matches 1.x (instruction.md, metadata.json,
/// screenshot pairs) with schema v4: each capture item carries its own
/// per-area note instead of one shared note.
final class FeedbackBundleWriter {
    private let encoder: JSONEncoder
    private let isoFormatter: ISO8601DateFormatter

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    }

    func write(captures: [AreaCapture], route: AppRoute) throws -> URL {
        guard let primary = captures.first else {
            throw MarkupError("Feedback needs at least one marked area.")
        }

        let now = Date()
        let id = makeID(date: now, appName: primary.area.routeName)
        let directory = route.feedbackDirectoryURL.appendingPathComponent(id, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var items: [FeedbackMetadata.CaptureItemMetadata] = []
        for (offset, capture) in captures.enumerated() {
            let index = offset + 1

            guard let annotatedImage = ScreenshotAnnotator.annotatedImage(
                source: capture.image,
                region: capture.region
            ) else {
                throw MarkupError("Could not annotate area \(index).")
            }

            let annotatedName = FeedbackAssetNames.annotatedScreenshot(for: index)
            let originalName = FeedbackAssetNames.originalScreenshot(for: index)
            try annotatedImage.writePNG(to: directory.appendingPathComponent(annotatedName))
            try capture.image.writePNG(to: directory.appendingPathComponent(originalName))

            let cgImage = capture.image.bestCGImage()
            let area = capture.area
            items.append(
                .init(
                    index: index,
                    label: nil,
                    note: area.trimmedNote,
                    app: .init(
                        bundleId: area.owner?.bundleId ?? MarkupArea.desktopRouteKey,
                        name: area.displayName,
                        windowTitle: area.owner?.windowTitle ?? area.displayName
                    ),
                    browser: area.owner?.browserPage,
                    capture: .init(
                        type: "liveArea/\(capture.source.rawValue)",
                        screenshotSize: .init(width: cgImage.width, height: cgImage.height),
                        region: capture.region
                    ),
                    assets: .init(
                        annotatedScreenshot: annotatedName,
                        originalScreenshot: originalName
                    )
                )
            )
        }

        guard let primaryItem = items.first else {
            throw MarkupError("Feedback needs at least one marked area.")
        }

        let metadata = FeedbackMetadata(
            id: id,
            schemaVersion: 4,
            createdAt: isoFormatter.string(from: now),
            app: primaryItem.app,
            browser: primaryItem.browser,
            project: .init(
                root: route.projectRoot,
                feedbackPath: route.feedbackPath
            ),
            capture: primaryItem.capture,
            assets: .init(
                annotatedScreenshot: primaryItem.assets.annotatedScreenshot,
                originalScreenshot: primaryItem.assets.originalScreenshot
            ),
            captures: items
        )

        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: directory.appendingPathComponent(FeedbackAssetNames.metadata), options: .atomic)

        let instruction = instructionMarkdown(captures: captures, metadata: metadata)
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
        captures: [AreaCapture],
        metadata: FeedbackMetadata
    ) -> String {
        let primaryArea = captures[0].area
        let intro = captures.count == 1
            ? "Improve the UI/UX/code issue shown in `\(FeedbackAssetNames.annotatedScreenshot)`."
            : "Improve the UI/UX/code issues shown across the \(captures.count) marked areas in this bundle."

        return """
        # Visual Feedback: \(primaryArea.owner?.windowTitle ?? primaryArea.displayName)

        \(intro)

        User note:
        > \(combinedNote(captures).replacingOccurrences(of: "\n", with: "\n> "))

        Marked areas:
        \(areasMarkdown(metadata.captures))

        Marked regions are stored as x/y/width/height values in `\(FeedbackAssetNames.metadata)` under `captures[n].capture.region` (image pixels, y from the top). `capture` and `assets` also describe Area 1 for compatibility.

        Context:
        - App under Area 1: \(primaryArea.displayName)
        - Bundle ID: \(primaryArea.owner?.bundleId ?? MarkupArea.desktopRouteKey)
        - Window title: \(primaryArea.owner?.windowTitle ?? primaryArea.displayName)
        \(browserContextMarkdown(primaryArea.owner?.browserPage))
        - Captured at: \(metadata.createdAt)
        - Captured live from the screen when the user saved (schema v4 live areas).

        Done when:
        - Each area's note is addressed.
        - The marked UI regions no longer exhibit the problems described.
        """
    }

    /// One combined note for the whole bundle, kept for tools (and the
    /// feedback inbox) that read the 1.x "User note:" block. Per-area notes
    /// remain authoritative in metadata and the area list below.
    private func combinedNote(_ captures: [AreaCapture]) -> String {
        let notes = captures.enumerated().compactMap { offset, capture -> String? in
            guard let note = capture.area.trimmedNote else { return nil }
            return captures.count == 1 ? note : "Area \(offset + 1): \(note)"
        }
        return notes.isEmpty ? "(no note)" : notes.joined(separator: "\n")
    }

    private func areasMarkdown(_ items: [FeedbackMetadata.CaptureItemMetadata]) -> String {
        items.map { item in
            var line = "- Area \(item.index): `\(item.assets.annotatedScreenshot)` — \(item.app.name)"
            if let note = item.note, !note.isEmpty {
                line += "\n  > \(note.replacingOccurrences(of: "\n", with: "\n  > "))"
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

private extension MarkupArea {
    var trimmedNote: String? {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
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
