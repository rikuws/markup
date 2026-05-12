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

    func write(
        captured: CapturedWindow,
        route: AppRoute,
        note: String,
        region: CaptureRegion,
        annotatedImage: NSImage,
        originalImage: NSImage,
        recordingURL: URL?
    ) throws -> URL {
        let now = Date()
        let id = makeID(date: now, appName: captured.appName)
        let directory = route.feedbackDirectoryURL.appendingPathComponent(id, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try annotatedImage.writePNG(to: directory.appendingPathComponent(FeedbackAssetNames.annotatedScreenshot))
        try originalImage.writePNG(to: directory.appendingPathComponent(FeedbackAssetNames.originalScreenshot))

        var copiedRecording: String?
        if let recordingURL {
            let destination = directory.appendingPathComponent(FeedbackAssetNames.recording)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: recordingURL, to: destination)
            copiedRecording = FeedbackAssetNames.recording
        }

        let image = originalImage.bestCGImage()
        let metadata = FeedbackMetadata(
            id: id,
            createdAt: isoFormatter.string(from: now),
            app: .init(
                bundleId: captured.bundleId,
                name: captured.appName,
                windowTitle: captured.windowTitle
            ),
            project: .init(
                root: route.projectRoot,
                feedbackPath: route.feedbackPath
            ),
            capture: .init(
                type: captured.windowID == nil ? "mainDisplayFallback" : "activeWindow",
                screenshotSize: .init(width: image.width, height: image.height),
                region: region
            ),
            assets: .init(
                annotatedScreenshot: FeedbackAssetNames.annotatedScreenshot,
                originalScreenshot: FeedbackAssetNames.originalScreenshot,
                recording: copiedRecording
            )
        )

        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: directory.appendingPathComponent(FeedbackAssetNames.metadata), options: .atomic)

        let instruction = instructionMarkdown(
            captured: captured,
            metadata: metadata,
            note: note,
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
        captured: CapturedWindow,
        metadata: FeedbackMetadata,
        note: String,
        hasRecording: Bool
    ) -> String {
        """
        # Visual Feedback: \(captured.windowTitle)

        Improve the UI/UX/code issue shown in `\(FeedbackAssetNames.annotatedScreenshot)`.

        User note:
        > \(note.replacingOccurrences(of: "\n", with: "\n> "))

        The highlighted region is at x/y/width/height from `\(FeedbackAssetNames.metadata)`.

        Context:
        - Captured app: \(captured.appName)
        - Bundle ID: \(captured.bundleId)
        - Window title: \(captured.windowTitle)
        - Captured at: \(metadata.createdAt)
        - Optional recording: \(hasRecording ? "`\(FeedbackAssetNames.recording)`" : "not attached")

        Done when:
        - The issue described in the note is addressed.
        - The highlighted UI region no longer exhibits the problem.
        """
    }
}

extension NSImage {
    func writePNG(to url: URL) throws {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw PunchlistError("Could not encode PNG image.")
        }

        try data.write(to: url, options: .atomic)
    }
}

struct PunchlistError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
