import Foundation

/// Swappable ASR backend for Markup dictation.
///
/// Capture, mute, retargeting, and `TechnicalTranscriptResolver` stay in
/// `NoteDictationController`. Engines only turn a finished audio buffer into
/// text. Live volatile results are an Apple `SpeechAnalyzer` concern; Parakeet
/// is batch-only (record → stop → transcribe).
///
/// Pipeline today:
/// `audio → TranscriptionEngine → TechnicalTranscriptResolver → insertion`
///
/// The resolver is the placeholder for a later contextual/technical correction
/// stage. Do not add naive whole-word swaps such as `you → UI` here.
protocol TranscriptionEngine: Sendable {
    var kind: TranscriptionEngineKind { get }
    func prepare() async throws
    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult
}

enum TranscriptionEngineKind: String, Codable, CaseIterable, Sendable {
    case appleSpeech
    case parakeet

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple SpeechAnalyzer"
        case .parakeet: return "Parakeet"
        }
    }

    var logName: String {
        switch self {
        case .appleSpeech: return "Apple"
        case .parakeet: return "Parakeet"
        }
    }

    /// Apple streams volatile results while listening. Parakeet waits until
    /// recording stops (or the dictation target changes) and then transcribes.
    var reportsPartialResults: Bool {
        self == .appleSpeech
    }
}

struct CapturedAudio: Sendable {
    var samples: [Float]
    var sampleRate: Double

    var duration: TimeInterval {
        sampleRate > 0 ? TimeInterval(samples.count) / sampleRate : 0
    }

    var isEmpty: Bool {
        samples.isEmpty
    }
}

struct TranscriptionResult: Sendable {
    var text: String
    var alternatives: [String]
    var inferenceDuration: TimeInterval
}

enum TranscriptionEngines {
    static func make(_ kind: TranscriptionEngineKind) -> any TranscriptionEngine {
        switch kind {
        case .appleSpeech:
            return AppleSpeechTranscriptionEngine()
        case .parakeet:
            return ParakeetTranscriptionEngine.shared
        }
    }
}

enum DictationLatencyLog {
    static func stage(_ message: String) {
        NSLog("[Dictation] %@", message)
    }

    static func summary(
        engine: TranscriptionEngineKind,
        audioDuration: TimeInterval,
        inference: TimeInterval,
        stopToText: TimeInterval
    ) {
        let realtimeFactor = inference > 0 && audioDuration > 0
            ? audioDuration / inference
            : 0
        NSLog(
            "[Dictation] engine=%@ audioDuration=%.2fs inference=%.3fs stopToText=%.3fs rtfx=%.1fx",
            engine.logName as NSString,
            audioDuration,
            inference,
            stopToText,
            realtimeFactor
        )
    }
}
