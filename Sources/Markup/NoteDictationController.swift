import AVFoundation
import AppKit
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
    private var transcriber: DictationTranscriber?
    private var speechDetector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tapInstalled = false
    private var converter: PCMBufferConverter?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var contextualPhrases: [String] = []
    private var pendingStart = false

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
            _ = try await makeTranscriber()
        } catch {
            NSLog("Markup: dictation prewarm failed: \(error.localizedDescription)")
        }
    }

    func adoptExistingNote(_ note: String) {
        committedText = note
        volatileText = ""
        publishTranscript()
    }

    func noteWasEdited(_ note: String) {
        committedText = note
        volatileText = ""
    }

    func setContextualPhrases(_ phrases: [String]) {
        contextualPhrases = phrases
        guard analyzer != nil else { return }
        Task { await applyContext() }
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

        do {
            let transcriber = try await Self.makeTranscriber()
            guard pendingStart, sessionID == currentSession, !Task.isCancelled else { return }

            let detector = SpeechDetector(
                detectionOptions: .init(sensitivityLevel: .medium),
                reportResults: true
            )
            let modules: [any SpeechModule] = [transcriber, detector]
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
            } else if let prepared = PCMBufferConverter(from: naturalFormat, to: analysisFormat) {
                converter = prepared
            } else {
                throw MarkupError("Could not convert microphone audio for dictation.")
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try await analyzer.prepareToAnalyze(in: analysisFormat)
            await applyContext(on: analyzer)
            guard pendingStart, sessionID == currentSession, !Task.isCancelled else {
                await analyzer.cancelAndFinishNow()
                return
            }

            let inputPair = AsyncStream.makeStream(
                of: AnalyzerInput.self,
                bufferingPolicy: .bufferingOldest(192)
            )

            inputNode.installTap(onBus: 0, bufferSize: 2_048, format: naturalFormat) { buffer, _ in
                let converted: AVAudioPCMBuffer?
                if let converter {
                    converted = converter.convert(buffer)
                } else {
                    converted = Self.copyPCMBuffer(buffer)
                }

                guard let converted else { return }
                _ = inputPair.continuation.yield(AnalyzerInput(buffer: converted))
            }

            engine.prepare()
            try engine.start()

            guard pendingStart, sessionID == currentSession, !Task.isCancelled else {
                inputNode.removeTap(onBus: 0)
                engine.stop()
                inputPair.continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }

            audioEngine = engine
            self.analyzer = analyzer
            self.transcriber = transcriber
            speechDetector = detector
            inputContinuation = inputPair.continuation
            tapInstalled = true
            self.converter = converter
            speechDetected = false
            state = .listening

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
                    for try await result in transcriber.results {
                        await MainActor.run {
                            self.handle(result: result, session: currentSession)
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

    private func handle(result: DictationTranscriber.Result, session: UUID) {
        guard sessionID == session, state == .listening else { return }

        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if result.isFinal {
            committedText = Self.join(committedText, text)
            volatileText = ""
        } else {
            volatileText = text
        }
        publishTranscript()
    }

    private func applyContext() async {
        guard let analyzer else { return }
        await applyContext(on: analyzer)
    }

    private func applyContext(on analyzer: SpeechAnalyzer) async {
        let context = AnalysisContext()
        if !contextualPhrases.isEmpty {
            context.contextualStrings[.general] = Array(contextualPhrases.prefix(ScreenshotTextIndex.maximumPhrases))
        }
        do {
            try await analyzer.setContext(context)
        } catch {
            NSLog("Markup: could not set dictation context: \(error.localizedDescription)")
        }
    }

    private func fail(_ error: Error) {
        NSLog("Markup: dictation failed: \(error.localizedDescription)")
        teardownSession(finalize: false)
        state = .unavailable
    }

    private func commitVolatile() {
        committedText = Self.join(committedText, volatileText)
        volatileText = ""
        publishTranscript()
    }

    private func publishTranscript() {
        onTranscriptChanged?(committedText, volatileText)
    }

    private func teardownSession(finalize: Bool) {
        let engine = audioEngine
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
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
        transcriber = nil
        speechDetector = nil
        analyzer = nil
        sessionID = UUID()

        guard let analyzerToFinish else { return }
        Task {
            if finalize {
                try? await analyzerToFinish.finalizeAndFinishThroughEndOfInput()
            } else {
                await analyzerToFinish.cancelAndFinishNow()
            }
        }
    }

    private static func makeTranscriber() async throws -> DictationTranscriber {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
            throw MarkupError("Dictation is not available for the current language.")
        }

        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .progressiveLongDictation
        )
        let modules: [any SpeechModule] = [transcriber]
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
        return transcriber
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
