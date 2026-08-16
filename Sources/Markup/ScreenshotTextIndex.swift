import AppKit
import Vision

enum ScreenshotTextIndex {
    static let maximumPhrases = 100

    static let glossary = [
        "button", "navbar", "navigation", "sheet", "modal", "padding",
        "screenshot", "toolbar", "sidebar", "toggle", "dropdown", "checkbox",
        "placeholder", "overlay", "badge", "tooltip", "spacing", "alignment"
    ]

    static func phrases(from cgImage: CGImage, extras: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            let phrase = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...48).contains(phrase.count) else { return }

            let key = phrase.lowercased()
            guard seen.insert(key).inserted else { return }
            ordered.append(phrase)
        }

        for extra in extras {
            append(extra)
            extra.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).forEach { token in
                append(String(token))
            }
        }

        for observation in recognizedStrings(in: cgImage) {
            append(observation)
            observation.split(whereSeparator: { $0.isWhitespace }).forEach { token in
                append(String(token))
            }
        }

        glossary.forEach(append)
        return Array(ordered.prefix(maximumPhrases))
    }

    private static func recognizedStrings(in cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015

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

        return observations.compactMap { observation in
            guard observation.confidence >= 0.35 else { return nil }
            return observation.topCandidates(1).first?.string
        }
    }
}
