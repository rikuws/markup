import Foundation
import FluidAudio

/// Parakeet TDT 0.6B v3 via FluidAudio / CoreML.
///
/// The `AsrManager` and compiled models live for the process lifetime so a
/// capture session does not download or compile on every push-to-talk. First
/// `prepare()` may fetch Hugging Face assets into
/// `~/Library/Application Support/FluidAudio/Models/`.
actor ParakeetTranscriptionEngine: TranscriptionEngine {
    static let shared = ParakeetTranscriptionEngine()

    nonisolated var kind: TranscriptionEngineKind { .parakeet }

    /// True when every required TDT v3 file and vocabulary is already on disk.
    nonisolated static func modelsAreOnDisk() -> Bool {
        let cache = AsrModels.defaultCacheDirectory(for: .v3)
        return AsrModels.modelsExist(at: cache, version: .v3)
    }

    private var manager: AsrManager?
    private var prepareTask: Task<AsrManager, Error>?

    func prepare() async throws {
        try await prepare(forceRedownload: false)
    }

    func prepare(forceRedownload: Bool) async throws {
        if forceRedownload {
            if let prepareTask {
                _ = try? await prepareTask.value
            }
            manager = nil
            self.prepareTask = nil
        }
        _ = try await preparedManager(forceRedownload: forceRedownload)
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscriptionResult {
        let samples = Self.paddedSamples(audio.samples)
        guard !samples.isEmpty else {
            return TranscriptionResult(text: "", alternatives: [], inferenceDuration: 0)
        }

        let manager = try await preparedManager(forceRedownload: false)
        return try await Self.runTranscription(on: manager, samples: samples)
    }

    private func preparedManager(forceRedownload: Bool) async throws -> AsrManager {
        if !forceRedownload, let manager, await manager.isAvailable {
            return manager
        }
        if let prepareTask {
            let manager = try await prepareTask.value
            self.manager = manager
            return manager
        }

        let task = Task<AsrManager, Error> {
            try await Self.loadManager(forceRedownload: forceRedownload)
        }
        prepareTask = task
        do {
            let manager = try await task.value
            self.manager = manager
            prepareTask = nil
            return manager
        } catch {
            prepareTask = nil
            throw error
        }
    }

    private static func loadManager(forceRedownload: Bool) async throws -> AsrManager {
        let cache = AsrModels.defaultCacheDirectory(for: .v3)
        let cached = !forceRedownload && AsrModels.modelsExist(at: cache, version: .v3)
        if cached {
            DictationLatencyLog.stage("Parakeet loading cached TDT 0.6B v3 from \(cache.path)")
        } else {
            DictationLatencyLog.stage(
                "Parakeet downloading TDT 0.6B v3 (FluidInference/parakeet-tdt-0.6b-v3-coreml) into \(cache.path)"
            )
        }
        let loadStarted = CFAbsoluteTimeGetCurrent()
        let progress: ProgressHandler = { snapshot in
            Task { @MainActor in
                ParakeetModelStatus.shared.handleDownloadProgress(snapshot)
            }
        }
        let models: AsrModels
        do {
            if forceRedownload {
                _ = try await AsrModels.download(
                    force: true,
                    version: .v3,
                    progressHandler: progress
                )
                models = try await AsrModels.loadFromCache(
                    version: .v3,
                    progressHandler: progress
                )
            } else {
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: progress
                )
            }
        } catch {
            DictationLatencyLog.stage("Parakeet model prepare failed: \(error.localizedDescription)")
            throw error
        }
        // v3 multilingual long-form is more stable without the 80ms mel-context
        // prepend used for English chunk seams.
        let config = ASRConfig(melChunkContext: false)
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        try await warm(manager)
        NSLog(
            "Markup: Parakeet TDT 0.6B v3 ready in %.2fs (cache %@)",
            CFAbsoluteTimeGetCurrent() - loadStarted,
            cache.path as NSString
        )
        return manager
    }

    /// FluidAudio rejects buffers shorter than 300 ms. Pad trailing silence
    /// so a clipped technical token still has a chance to decode.
    private static func paddedSamples(_ samples: [Float]) -> [Float] {
        let minimum = Int(DictationAudioFormat.parakeetSampleRate * 0.3)
        guard !samples.isEmpty, samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    private static func runTranscription(on manager: AsrManager, samples: [Float]) async throws -> TranscriptionResult {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let inferenceStarted = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: preferredLanguage()
            )
            return TranscriptionResult(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                alternatives: [],
                inferenceDuration: result.processingTime > 0
                    ? result.processingTime
                    : CFAbsoluteTimeGetCurrent() - inferenceStarted
            )
        } catch ASRError.invalidAudioData {
            DictationLatencyLog.stage("Parakeet skipped short/empty audio samples=\(samples.count)")
            return TranscriptionResult(text: "", alternatives: [], inferenceDuration: 0)
        }
    }

    /// Compile ANE programs once so the first real utterance is not a cold start.
    private static func warm(_ manager: AsrManager) async throws {
        let silence = [Float](repeating: 0, count: Int(DictationAudioFormat.parakeetSampleRate * 1.0))
        do {
            _ = try await runTranscription(on: manager, samples: silence)
            DictationLatencyLog.stage("Parakeet ANE warm inference finished")
        } catch {
            DictationLatencyLog.stage("Parakeet warm inference skipped: \(error.localizedDescription)")
        }
    }

    /// Script-aware token filter for v3. Finnish and English are both Latin, so
    /// mixed FI+EN technical speech stays in-script. This is not a Finnish-only
    /// language lock and does not bias toward terms such as SwiftUI.
    private static func preferredLanguage(from locale: Locale = .current) -> Language {
        let code = locale.language.languageCode?.identifier ?? "fi"
        if let language = Language(rawValue: code) {
            return language
        }
        return .finnish
    }
}
