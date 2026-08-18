import AVFoundation
import Accelerate
import AppKit
import CoreMedia
import Darwin
import Foundation
import Speech

@MainActor
final class NoteDictationController {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case muted
        case unavailable
    }

    var onStateChanged: ((State) -> Void)?
    var onTranscriptChanged: ((String, String) -> Void)?
    var onSpeechDetectedChanged: ((Bool) -> Void)?
    var onAudioLevelChanged: ((Float) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChanged?(state)
        }
    }

    private(set) var committedText = ""
    private(set) var volatileText = ""
    private(set) var speechDetected = false {
        didSet {
            guard oldValue != speechDetected else { return }
            onSpeechDetectedChanged?(speechDetected)
        }
    }

    var isListening: Bool { state == .listening }

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var preparedTranscriber: PreparedTranscriber?
    private var speechDetector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false
    private var converter: PCMBufferConverter?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var pendingStart = false

    /// Note text that already belongs to the current target (typed or
    /// adopted from an existing area). New speech is appended to this.
    private var baseNote = ""
    /// Audio time at which the current target started. Results that end
    /// at or before this are previous-area speech and are ignored.
    private var targetStart = CMTime.zero
    private var lastHeardEnd = CMTime.zero
    /// In-flight utterance at the last retarget, used only to clip an
    /// untimed result that still covers the previous area's tail.
    private var clipPrefix = ""
    private var targetFinalized = AttributedString()
    private var targetVolatile = AttributedString()
    private var resolver = TechnicalTranscriptResolver()
    /// True while the fallback `DictationTranscriber` is running, so session
    /// vocabulary can be pushed through `AnalysisContext`.
    private var usesDictationContext = false
    private var levelSink: AudioLevelSink?

    nonisolated static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    nonisolated static var needsMicrophonePrompt: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    nonisolated static func requestMicrophoneAccessIfNeeded() async {
        guard needsMicrophonePrompt else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func prewarm() async {
        do {
            _ = try await makeEngine()
        } catch {
            NSLog("Markup: dictation prewarm failed: \(error.localizedDescription)")
        }
    }

    func adoptExistingNote(_ note: String) {
        beginNewTarget(adopting: note)
    }

    func learnFromEdit(previous: String, edited: String) {
        resolver.learnCorrection(from: previous, to: edited)
    }

    func updateSessionTerms(_ terms: [String]) {
        var unique: [String] = []
        var seen = Set<String>()
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                unique.append(trimmed)
            }
        }
        resolver.sessionTerms = unique
        guard usesDictationContext, analyzer != nil else { return }
        Task { await self.pushDictationContext() }
    }

    func noteWasEdited(_ note: String) {
        resolver.learnCorrection(from: committedText, to: note)
        baseNote = note
        targetStart = lastHeardEnd
        targetFinalized = AttributedString()
        targetVolatile = AttributedString()
        clipPrefix = ""
        committedText = note
        volatileText = ""
        publishTranscript()
    }

    /// Retargets the transcript stream to a new note without stopping the
    /// analyzer. Later results are kept only if their audio starts after
    /// this moment, so a new area never inherits earlier speech.
    func beginNewTarget(adopting note: String = "") {
        clipPrefix = String(targetVolatile.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        baseNote = note
        targetStart = lastHeardEnd
        targetFinalized = AttributedString()
        targetVolatile = AttributedString()
        committedText = note
        volatileText = ""
        publishTranscript()
    }

    func startListening() {
        pendingStart = true
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.beginSession()
        }
    }

    func mute() {
        pendingStart = false
        startTask?.cancel()
        startTask = nil
        commitVolatile()
        teardownSession(finalize: true)
        if state != .unavailable {
            state = .muted
        }
    }

    func toggleMuted() {
        switch state {
        case .muted, .idle:
            startListening()
        case .listening, .preparing:
            mute()
        case .unavailable:
            break
        }
    }

    func teardown() {
        pendingStart = false
        startTask?.cancel()
        startTask = nil
        commitVolatile()
        teardownSession(finalize: false)
        if state != .unavailable {
            state = .idle
        }
    }

    private func beginSession() async {
        guard pendingStart, !Task.isCancelled else { return }

        await Self.requestMicrophoneAccessIfNeeded()
        guard pendingStart, !Task.isCancelled else { return }

        guard Self.hasMicrophoneAccess else {
            state = .unavailable
            return
        }

        state = .preparing
        let currentSession = UUID()
        sessionID = currentSession
        resetAudioClockKeepingNote()

        do {
            let prepared = try await Self.makeEngine()
            guard pendingStart, sessionID == currentSession, !Task.isCancelled else { return }

            let transcriberModule: any SpeechModule
            switch prepared {
            case .speech(let transcriber):
                transcriberModule = transcriber
            case .dictation(let transcriber):
                transcriberModule = transcriber
            }

            let detector = SpeechDetector(
                detectionOptions: .init(sensitivityLevel: .medium),
                reportResults: true
            )
            let modules: [any SpeechModule] = [transcriberModule, detector]
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let naturalFormat = inputNode.outputFormat(forBus: 0)
            guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
                throw MarkupError("No microphone input format is available.")
            }

            guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            ) else {
                throw MarkupError("Speech analysis is not available on this Mac.")
            }

            let converter: PCMBufferConverter?
            if Self.formatsMatch(naturalFormat, analysisFormat) {
                converter = nil
            } else if let preparedConverter = PCMBufferConverter(from: naturalFormat, to: analysisFormat) {
                converter = preparedConverter
            } else {
                throw MarkupError("Could not convert microphone audio for dictation.")
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await analyzer.prepareToAnalyze(in: analysisFormat)
            guard pendingStart, sessionID == currentSession, !Task.isCancelled else {
                await analyzer.cancelAndFinishNow()
                return
            }

            let inputPair = AsyncStream.makeStream(
                of: AnalyzerInput.self,
                bufferingPolicy: .bufferingOldest(192)
            )

            let sink = AudioLevelSink()
            sink.setHandler { [weak self] level in
                self?.handleAudioLevel(level)
            }
            self.levelSink = sink

            inputNode.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { buffer, _ in
                let converted: AVAudioPCMBuffer?
                if let converter {
                    converted = converter.convert(buffer)
                } else {
                    converted = Self.copyPCMBuffer(buffer)
                }

                guard let converted else { return }
                sink.ingest(converted)
                _ = inputPair.continuation.yield(AnalyzerInput(buffer: converted))
            }

            engine.prepare()
            try engine.start()

            guard pendingStart, sessionID == currentSession, !Task.isCancelled else {
                inputNode.removeTap(onBus: 0)
                sink.stop()
                self.levelSink = nil
                engine.stop()
                inputPair.continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }

            audioEngine = engine
            self.analyzer = analyzer
            preparedTranscriber = prepared
            speechDetector = detector
            inputContinuation = inputPair.continuation
            tapInstalled = true
            self.converter = converter
            speechDetected = false
            usesDictationContext = {
                if case .dictation = prepared { return true }
                return false
            }()
            state = .listening
            await pushDictationContext()
            guard pendingStart, sessionID == currentSession, !Task.isCancelled else { return }

            analysisTask = Task {
                do {
                    try await analyzer.start(inputSequence: inputPair.stream)
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        self.fail(error)
                    }
                }
            }

            resultTask = Task {
                do {
                    switch prepared {
                    case .speech(let transcriber):
                        for try await result in transcriber.results {
                            await MainActor.run {
                                self.ingest(
                                    range: result.range,
                                    primary: result.text,
                                    alternatives: result.alternatives,
                                    isFinal: result.isFinal,
                                    session: currentSession
                                )
                            }
                        }
                    case .dictation(let transcriber):
                        for try await result in transcriber.results {
                            await MainActor.run {
                                self.ingest(
                                    range: result.range,
                                    primary: result.text,
                                    alternatives: result.alternatives,
                                    isFinal: result.isFinal,
                                    session: currentSession
                                )
                            }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        self.fail(error)
                    }
                }
            }

            detectionTask = Task {
                do {
                    for try await result in detector.results {
                        await MainActor.run {
                            guard self.sessionID == currentSession else { return }
                            self.speechDetected = result.speechDetected
                        }
                    }
                } catch {
                    return
                }
            }
        } catch {
            fail(error)
        }
    }

    private func ingest(
        range: CMTimeRange,
        primary: AttributedString,
        alternatives: [AttributedString],
        isFinal: Bool,
        session: UUID
    ) {
        let preferred = resolver.preferredTranscription(
            primary: primary,
            alternatives: alternatives
        )
        if isFinal {
            let original = String(primary.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = String(preferred.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if original != chosen {
                NSLog("Markup: dictation alternative “\(original)” → “\(chosen)”")
            }
        }
        handle(range: range, text: preferred, isFinal: isFinal, session: session)
    }

    private func handle(range: CMTimeRange, text: AttributedString, isFinal: Bool, session: UUID) {
        guard sessionID == session, state == .listening else { return }

        lastHeardEnd = CMTimeMaximum(lastHeardEnd, range.end)

        let clipped = clipToCurrentTarget(text, range: range)
        let clippedPlain = String(clipped.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clippedPlain.isEmpty else { return }

        if Self.hasAudioTiming(clipped) {
            if isFinal {
                Self.replacing(&targetFinalized, intersecting: range, with: clipped)
                if let overlapping = targetVolatile.rangeOfAudioTimeRangeAttributes(intersecting: range) {
                    targetVolatile.removeSubrange(overlapping)
                }
            } else {
                Self.replacing(&targetVolatile, intersecting: range, with: clipped)
            }
        } else if isFinal {
            targetFinalized = AttributedString(Self.join(Self.plain(targetFinalized), clippedPlain))
            targetVolatile = AttributedString()
        } else {
            targetVolatile = AttributedString(clippedPlain)
        }

        let spokenFinal = Self.plain(targetFinalized)
        let spokenVolatile = Self.plain(targetVolatile)
        let resolvedFinal = resolver.resolvedSpeech(spokenFinal)
        let resolvedVolatile = resolver.resolvedSpeech(spokenVolatile)
        if isFinal, spokenFinal != resolvedFinal {
            NSLog("Markup: dictation rewrite “\(spokenFinal)” → “\(resolvedFinal)”")
        }

        committedText = Self.join(baseNote, resolvedFinal)
        volatileText = resolvedVolatile
        publishTranscript()
    }

    private func pushDictationContext() async {
        guard usesDictationContext, let analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings = [.general: resolver.contextualPhrases]
        do {
            try await analyzer.setContext(context)
        } catch {
            NSLog("Markup: dictation context update failed: \(error.localizedDescription)")
        }
    }

    private func clipToCurrentTarget(_ text: AttributedString, range: CMTimeRange) -> AttributedString {
        if targetStart > .zero, range.end <= targetStart {
            return AttributedString()
        }
        if targetStart <= .zero || range.start >= targetStart {
            clipPrefix = ""
            return text
        }

        var output = AttributedString()
        var hadTiming = false
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            hadTiming = true
            guard timeRange.start >= targetStart else { continue }
            Self.append(&output, AttributedString(text[run.range]))
        }
        if hadTiming {
            return output
        }

        return AttributedString(Self.strippingPrefix(clipPrefix, from: String(text.characters)))
    }

    private func fail(_ error: Error) {
        NSLog("Markup: dictation failed: \(error.localizedDescription)")
        teardownSession(finalize: false)
        state = .unavailable
    }

    private func commitVolatile() {
        committedText = Self.join(committedText, volatileText)
        volatileText = ""
        baseNote = committedText
        targetStart = lastHeardEnd
        targetFinalized = AttributedString()
        targetVolatile = AttributedString()
        clipPrefix = ""
        publishTranscript()
    }

    private func publishTranscript() {
        onTranscriptChanged?(committedText, volatileText)
    }

    private func handleAudioLevel(_ level: Float) {
        guard state == .listening else { return }
        onAudioLevelChanged?(level)
    }

    private func resetAudioClockKeepingNote() {
        lastHeardEnd = .zero
        targetStart = .zero
        clipPrefix = ""
        targetFinalized = AttributedString()
        targetVolatile = AttributedString()
        baseNote = committedText
        volatileText = ""
    }

    private func teardownSession(finalize: Bool) {
        let engine = audioEngine
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        levelSink?.stop()
        levelSink = nil
        engine?.stop()
        audioEngine = nil

        if let converter {
            for tail in converter.drain() {
                _ = inputContinuation?.yield(AnalyzerInput(buffer: tail))
            }
        }
        converter = nil
        inputContinuation?.finish()
        inputContinuation = nil

        analysisTask?.cancel()
        resultTask?.cancel()
        detectionTask?.cancel()
        analysisTask = nil
        resultTask = nil
        detectionTask = nil
        speechDetected = false

        let analyzerToFinish = analyzer
        preparedTranscriber = nil
        speechDetector = nil
        analyzer = nil
        usesDictationContext = false
        sessionID = UUID()
        resetAudioClockKeepingNote()

        guard let analyzerToFinish else { return }
        Task {
            if finalize {
                try? await analyzerToFinish.finalizeAndFinishThroughEndOfInput()
            } else {
                await analyzerToFinish.cancelAndFinishNow()
            }
        }
    }

    private static func makeEngine() async throws -> PreparedTranscriber {
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
            NSLog("Markup: dictation engine SpeechTranscriber (\(locale.identifier))")
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
        NSLog("Markup: dictation engine DictationTranscriber fallback (\(locale.identifier))")
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

    private static func replacing(
        _ transcript: inout AttributedString,
        intersecting timeRange: CMTimeRange,
        with addition: AttributedString
    ) {
        guard !addition.characters.isEmpty else { return }
        if let existing = transcript.rangeOfAudioTimeRangeAttributes(intersecting: timeRange) {
            transcript.replaceSubrange(existing, with: addition)
            return
        }
        append(&transcript, addition)
    }

    private static func append(_ transcript: inout AttributedString, _ addition: AttributedString) {
        guard !addition.characters.isEmpty else { return }
        if !transcript.characters.isEmpty {
            let lastIsSpace = transcript.characters.last?.isWhitespace == true
            let firstIsSpace = addition.characters.first?.isWhitespace == true
            if !lastIsSpace, !firstIsSpace {
                transcript.append(AttributedString(" "))
            }
        }
        transcript.append(addition)
    }

    private static func hasAudioTiming(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.audioTimeRange != nil }
    }

    private static func plain(_ text: AttributedString) -> String {
        String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clip an untimed straddling result. Never return the whole string on
    /// mismatch — that is how old speech used to leak into new areas.
    private static func strippingPrefix(_ prefix: String, from text: String) -> String {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return haystack }

        let needleLower = needle.lowercased()
        let haystackLower = haystack.lowercased()
        if haystackLower.hasPrefix(needleLower) {
            return String(haystack.dropFirst(needle.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if needleLower.hasPrefix(haystackLower) {
            return ""
        }
        return ""
    }

    private static func join(_ leading: String, _ trailing: String) -> String {
        let left = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if left.last?.isWhitespace == true || right.first?.isWhitespace == true {
            return left + right
        }
        if let last = left.last, ".!?,;:".contains(last) {
            return left + " " + right
        }
        return left + " " + right
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return copy
    }
}

private enum PreparedTranscriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)
}

private final class PCMBufferConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        convert(buffer, endOfStream: false)
    }

    func drain() -> [AVAudioPCMBuffer] {
        guard let buffer = convert(nil, endOfStream: true) else { return [] }
        return [buffer]
    }

    private func convert(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) -> AVAudioPCMBuffer? {
        let inFrames = buffer?.frameLength ?? 0
        let ratio = outputFormat.sampleRate / (buffer?.format.sampleRate ?? outputFormat.sampleRate)
        let capacity = max(1, AVAudioFrameCount((Double(inFrames) * ratio).rounded(.up)) + (endOfStream ? 1_024 : 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if endOfStream {
                status.pointee = .endOfStream
                return nil
            }
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        if error != nil || output.frameLength == 0 {
            return nil
        }
        return output
    }
}

/// RMS/peak from the mic tap, published on the main queue at ~50 Hz.
private final class AudioLevelSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Float) -> Void)?
    private var lastPublish = 0.0

    func setHandler(_ handler: ((Float) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func stop() {
        setHandler(nil)
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let level = PCMAmplitude.normalized(from: buffer)
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let shouldPublish = now - lastPublish >= 1.0 / 50.0
        if shouldPublish {
            lastPublish = now
        }
        let handler = self.handler
        lock.unlock()
        guard shouldPublish, let handler else { return }
        DispatchQueue.main.async {
            handler(level)
        }
    }
}

private enum PCMAmplitude {
    static func normalized(from buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return 0 }

        let channelCount = Int(buffer.format.channelCount)
        var rms: Float = 0
        var peak: Float = 0
        for channel in 0..<max(channelCount, 1) {
            let pointer = channels[channel]
            var channelRMS: Float = 0
            var channelPeak: Float = 0
            vDSP_rmsqv(pointer, 1, &channelRMS, vDSP_Length(frames))
            vDSP_maxmgv(pointer, 1, &channelPeak, vDSP_Length(frames))
            rms = max(rms, channelRMS)
            peak = max(peak, channelPeak)
        }

        let mixed = rms * 0.62 + peak * 0.38
        if mixed < 0.0035 { return 0 }
        return Float(min(1, pow(Double(mixed) * 12.5, 0.52)))
    }
}
