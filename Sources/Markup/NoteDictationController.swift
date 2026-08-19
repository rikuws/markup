import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Speech

@MainActor
final class NoteDictationController {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
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
    var usesBatchTranscription: Bool { !engineKind.reportsPartialResults }

    private let engineKind: TranscriptionEngineKind
    private let transcriptionEngine: any TranscriptionEngine

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var preparedTranscriber: PreparedTranscriber?
    private var speechDetector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false
    private var converter: PCMBufferConverter?
    private var sampleAccumulator: PCMSampleAccumulator?
    private var heldAudio: CapturedAudio?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var pendingStart = false
    private var recordingStartedAt: CFAbsoluteTime?
    private var stopRequestedAt: CFAbsoluteTime?

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

    init(engineKind: TranscriptionEngineKind = .appleSpeech) {
        self.engineKind = engineKind
        self.transcriptionEngine = TranscriptionEngines.make(engineKind)
    }

    static func prewarm(engine kind: TranscriptionEngineKind) async {
        do {
            try await TranscriptionEngines.make(kind).prepare()
        } catch {
            NSLog("Markup: dictation prewarm failed (%@): %@", kind.logName, error.localizedDescription)
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
    ///
    /// For batch engines, call `takeHeldAudio()` after this to transcribe
    /// speech that belonged to the previous target. Pass `captureHeldAudio:
    /// false` when the current buffer already belongs to `note` (for example
    /// after clicking an existing area).
    func beginNewTarget(adopting note: String = "", captureHeldAudio: Bool = true) {
        if usesBatchTranscription, captureHeldAudio {
            heldAudio = sampleAccumulator?.take()
            stopRequestedAt = CFAbsoluteTimeGetCurrent()
        }
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

    /// Keep the current capture buffer and point committed text at `note`.
    /// Used when a new-area drag is abandoned so speech during the drag
    /// still belongs to the previous area.
    func resumeTarget(adopting note: String) {
        heldAudio = nil
        baseNote = note
        targetStart = lastHeardEnd
        targetFinalized = AttributedString()
        targetVolatile = AttributedString()
        clipPrefix = ""
        committedText = note
        volatileText = ""
        publishTranscript()
    }

    func takeHeldAudio() -> CapturedAudio? {
        let audio = heldAudio
        heldAudio = nil
        return audio
    }

    /// Transcribes the current (or held) capture for batch engines, or
    /// commits volatile Apple text. Safe to call on the Apple path.
    func finalizeCurrentUtterance() async {
        if usesBatchTranscription {
            let audio = sampleAccumulator?.take() ?? CapturedAudio(samples: [], sampleRate: DictationAudioFormat.parakeetSampleRate)
            let spoken = await runBatchTranscription(audio)
            applySpokenText(spoken)
            return
        }
        commitVolatile()
    }

    /// Transcribe audio that `beginNewTarget()` sliced off for the previous area.
    func transcribeHeldAudio() async -> String {
        guard let audio = takeHeldAudio() else { return "" }
        return await runBatchTranscription(audio)
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
        stopRequestedAt = CFAbsoluteTimeGetCurrent()
        DictationLatencyLog.stage("dictation stopped engine=\(engineKind.logName)")
        if usesBatchTranscription, state == .listening || state == .preparing {
            state = .transcribing
            stopCaptureKeepingAccumulator()
            transcribeTask?.cancel()
            transcribeTask = Task { [weak self] in
                guard let self else { return }
                await self.finalizeCurrentUtterance()
                guard !Task.isCancelled else { return }
                self.teardownSession(finalize: false)
                if self.state != .unavailable {
                    self.state = .muted
                }
            }
            return
        }
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
        case .transcribing, .unavailable:
            break
        }
    }

    func teardown() {
        pendingStart = false
        startTask?.cancel()
        startTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        stopRequestedAt = CFAbsoluteTimeGetCurrent()
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
        recordingStartedAt = CFAbsoluteTimeGetCurrent()
        stopRequestedAt = nil
        heldAudio = nil

        do {
            if usesBatchTranscription {
                try await beginParakeetSession(session: currentSession)
            } else {
                try await beginAppleSession(session: currentSession)
            }
        } catch {
            fail(error)
        }
    }

    private func beginParakeetSession(session currentSession: UUID) async throws {
        DictationLatencyLog.stage("Parakeet session prepare")
        try await transcriptionEngine.prepare()
        guard pendingStart, sessionID == currentSession, !Task.isCancelled else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw MarkupError("No microphone input format is available.")
        }
        guard let parakeetFormat = DictationAudioFormat.parakeetFormat() else {
            throw MarkupError("Could not create a 16 kHz mono capture format.")
        }
        guard let accumulator = PCMSampleAccumulator(from: naturalFormat, outputFormat: parakeetFormat) else {
            throw MarkupError("Could not convert microphone audio for Parakeet.")
        }

        let sink = AudioLevelSink()
        sink.setHandler { [weak self] level in
            self?.handleAudioLevel(level)
        }
        self.levelSink = sink

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { buffer, _ in
            sink.ingest(buffer)
            accumulator.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            sink.stop()
            self.levelSink = nil
            throw error
        }

        guard pendingStart, sessionID == currentSession, !Task.isCancelled else {
            inputNode.removeTap(onBus: 0)
            sink.stop()
            self.levelSink = nil
            engine.stop()
            return
        }

        audioEngine = engine
        sampleAccumulator = accumulator
        tapInstalled = true
        speechDetected = false
        usesDictationContext = false
        state = .listening
        NSLog("Markup: dictation engine Parakeet TDT 0.6B v3")
    }

    private func beginAppleSession(session currentSession: UUID) async throws {
        let prepared = try await AppleSpeechTranscriptionEngine.makePreparedTranscriber()
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
        if DictationAudioFormat.formatsMatch(naturalFormat, analysisFormat) {
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
                converted = DictationAudioFormat.copyPCMBuffer(buffer)
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
        logAppleStopToTextIfNeeded()
    }

    private func logAppleStopToTextIfNeeded() {
        guard !usesBatchTranscription, let stopRequestedAt else { return }
        let audioDuration: TimeInterval
        if let recordingStartedAt {
            audioDuration = stopRequestedAt - recordingStartedAt
        } else {
            audioDuration = 0
        }
        DictationLatencyLog.summary(
            engine: engineKind,
            audioDuration: audioDuration,
            inference: 0,
            stopToText: CFAbsoluteTimeGetCurrent() - stopRequestedAt
        )
        DictationLatencyLog.stage("text inserted")
        self.stopRequestedAt = nil
    }

    /// audio → ASR → TechnicalTranscriptResolver → insertion
    private func runBatchTranscription(_ audio: CapturedAudio) async -> String {
        DictationLatencyLog.stage("audio ready duration=\(String(format: "%.2f", audio.duration))s samples=\(audio.samples.count)")
        guard !audio.isEmpty else {
            DictationLatencyLog.stage("empty transcription")
            return ""
        }

        let previousState = state
        if state == .listening {
            state = .transcribing
        }
        DictationLatencyLog.stage("inference started")
        do {
            let result = try await transcriptionEngine.transcribe(audio)
            DictationLatencyLog.stage("transcription available")
            let spoken = resolver.resolvedSpeech(result.text)
            if spoken != result.text {
                NSLog("Markup: dictation rewrite “\(result.text)” → “\(spoken)”")
            }
            if spoken.isEmpty {
                DictationLatencyLog.stage("empty transcription")
            }
            let stopToText: TimeInterval
            if let stopRequestedAt {
                stopToText = CFAbsoluteTimeGetCurrent() - stopRequestedAt
            } else {
                stopToText = result.inferenceDuration
            }
            DictationLatencyLog.summary(
                engine: engineKind,
                audioDuration: audio.duration,
                inference: result.inferenceDuration,
                stopToText: stopToText
            )
            DictationLatencyLog.stage("text inserted")
            if state == .transcribing, previousState == .listening {
                state = .listening
            }
            return spoken
        } catch {
            NSLog("Markup: %@ transcription failed: %@", engineKind.logName, error.localizedDescription)
            if state == .transcribing, previousState == .listening {
                state = .listening
            }
            return ""
        }
    }

    private func applySpokenText(_ spoken: String) {
        committedText = Self.join(baseNote, spoken)
        volatileText = ""
        baseNote = committedText
        publishTranscript()
    }

    private func publishTranscript() {
        onTranscriptChanged?(committedText, volatileText)
    }

    private func handleAudioLevel(_ level: Float) {
        guard state == .listening else { return }
        if usesBatchTranscription {
            speechDetected = level > 0.04
        }
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

    /// Stop the mic tap without draining the sample accumulator, so mute can
    /// freeze audio then transcribe off the main actor.
    private func stopCaptureKeepingAccumulator() {
        let engine = audioEngine
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        levelSink?.stop()
        levelSink = nil
        engine?.stop()
        audioEngine = nil
    }

    private func teardownSession(finalize: Bool) {
        stopCaptureKeepingAccumulator()

        if let converter {
            for tail in converter.drain() {
                _ = inputContinuation?.yield(AnalyzerInput(buffer: tail))
            }
        }
        converter = nil
        sampleAccumulator = nil
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
}
