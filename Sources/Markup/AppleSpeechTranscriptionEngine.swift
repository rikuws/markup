import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's `SpeechAnalyzer` / `SpeechTranscriber` engine.
///
/// Live dictation still uses the streaming session in `NoteDictationController`.
/// `transcribe(_:)` is a one-shot path over a captured buffer so Apple and
/// Parakeet can share the same `TranscriptionEngine` boundary.
struct AppleSpeechTranscriptionEngine: TranscriptionEngine {
    let kind = TranscriptionEngineKind.appleSpeech

    func prepare() async throws {
        _ = try await Self.makePreparedTranscriber()
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        let inferenceStarted = CFAbsoluteTimeGetCurrent()
        let prepared = try await Self.makePreparedTranscriber()
        let transcriberModule: any SpeechModule
        switch prepared {
        case .speech(let transcriber):
            transcriberModule = transcriber
        case .dictation(let transcriber):
            transcriberModule = transcriber
        }

        guard let buffer = DictationAudioFormat.pcmBuffer(from: audio) else {
            throw MarkupError("Could not build an audio buffer for Apple Speech.")
        }

        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriberModule],
            considering: buffer.format
        ) else {
            throw MarkupError("Speech analysis is not available on this Mac.")
        }

        let inputBuffer: AVAudioPCMBuffer
        if DictationAudioFormat.formatsMatch(buffer.format, analysisFormat) {
            inputBuffer = buffer
        } else if let converter = PCMBufferConverter(from: buffer.format, to: analysisFormat),
                  let converted = converter.convert(buffer) {
            inputBuffer = converted
        } else {
            throw MarkupError("Could not convert captured audio for Apple Speech.")
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriberModule],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        let inputPair = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputPair.continuation.yield(AnalyzerInput(buffer: inputBuffer))
        inputPair.continuation.finish()

        let collected = TranscriptionCollector()
        let resultTask = Task {
            switch prepared {
            case .speech(let transcriber):
                for try await result in transcriber.results {
                    collected.update(result.text, alternatives: result.alternatives)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    collected.update(result.text, alternatives: result.alternatives)
                }
            }
        }

        try await analyzer.start(inputSequence: inputPair.stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultTask.value

        return TranscriptionResult(
            text: collected.text,
            alternatives: collected.alternatives,
            inferenceDuration: CFAbsoluteTimeGetCurrent() - inferenceStarted
        )
    }

    static func makePreparedTranscriber() async throws -> PreparedTranscriber {
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions
                    .subtracting([.fastResults])
                    .union([.alternativeTranscriptions]),
                attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])
            )
            try await ensureAssets(for: [transcriber], locale: locale)
            NSLog("Markup: dictation engine SpeechTranscriber (%@)", locale.identifier)
            return .speech(transcriber)
        }

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
            throw MarkupError("Dictation is not available for the current language.")
        }
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.alternativeTranscriptions]),
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
        try await ensureAssets(for: [transcriber], locale: locale)
        NSLog("Markup: dictation engine DictationTranscriber fallback (%@)", locale.identifier)
        return .dictation(transcriber)
    }

    private static func ensureAssets(for modules: [any SpeechModule], locale: Locale) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            _ = try? await AssetInventory.reserve(locale: locale)
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            _ = try? await AssetInventory.reserve(locale: locale)
        case .unsupported:
            throw MarkupError("Dictation is not supported on this Mac.")
        @unknown default:
            throw MarkupError("Dictation assets are unavailable.")
        }
    }
}

enum PreparedTranscriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)
}

private final class TranscriptionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedText = ""
    private var storedAlternatives: [String] = []

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storedText
    }

    var alternatives: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedAlternatives
    }

    func update(_ text: AttributedString, alternatives: [AttributedString]) {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let alts = alternatives.map {
            String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lock.lock()
        storedText = plain
        storedAlternatives = alts
        lock.unlock()
    }
}
