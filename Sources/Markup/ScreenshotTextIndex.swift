import AppKit
import Vision

enum ScreenshotTextIndex {
    static let maximumLines = 40

    /// Visible strings in the marked region, for the saved feedback bundle.
    /// Dictation does not use this — agents read it from instruction.md.
    static func visibleText(from image: NSImage, region: CaptureRegion) -> [String] {
        let cgImage = image.bestCGImage()
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let crop = CGRect(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height
        ).intersection(bounds)

        let focused: CGImage
        if crop.isNull || crop.width < 2 || crop.height < 2 {
            focused = cgImage
        } else {
            focused = cgImage.cropping(to: crop) ?? cgImage
        }

        let lines = recognizedStrings(in: focused)
        if lines.isEmpty, focused.width != cgImage.width || focused.height != cgImage.height {
            return recognizedStrings(in: cgImage)
        }
        return lines
    }

    private static func recognizedStrings(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("Markup: screenshot OCR failed: \(error.localizedDescription)")
            return []
        }

        let observations = (request.results ?? []).sorted { lhs, rhs in
            lhs.confidence > rhs.confidence
        }

        var ordered: [String] = []
        var seen = Set<String>()
        for observation in observations {
            guard observation.confidence >= 0.35 else { continue }
            guard let raw = observation.topCandidates(1).first?.string else { continue }
            let phrase = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...80).contains(phrase.count) else { continue }
            let key = phrase.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(phrase)
            if ordered.count >= maximumLines { break }
        }
        return ordered
    }
}
