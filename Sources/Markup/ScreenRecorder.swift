import AVFoundation
import AppKit
import ScreenCaptureKit

final class ScreenRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var screenCaptureKitSession: AnyObject?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var onStarted: (() -> Void)?
    private var destinationURL: URL?
    private var stopWorkItem: DispatchWorkItem?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var didComplete = false

    func record(
        duration: TimeInterval = 10,
        onStarted: (() -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard session == nil, screenCaptureKitSession == nil else {
            completion(.failure(MarkupError("A recording is already in progress.")))
            return
        }

        guard duration > 0 else {
            completion(.failure(MarkupError("Recording duration must be greater than zero.")))
            return
        }

        if #available(macOS 15.0, *) {
            let recorder = ScreenCaptureKitRecorder(
                duration: duration,
                onStarted: onStarted,
                completion: { [weak self] result in
                    self?.screenCaptureKitSession = nil
                    completion(result)
                }
            )
            screenCaptureKitSession = recorder
            recorder.start()
            return
        }

        recordWithAVCapture(duration: duration, onStarted: onStarted, completion: completion)
    }

    private func recordWithAVCapture(
        duration: TimeInterval,
        onStarted: (() -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-\(UUID().uuidString).mov")

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
            completion(.failure(MarkupError("Could not create screen recording input.")))
            return
        }
        input.capturesCursor = true
        input.capturesMouseClicks = true

        let output = AVCaptureMovieFileOutput()

        guard session.canAddInput(input), session.canAddOutput(output) else {
            completion(.failure(MarkupError("Could not configure screen recording.")))
            return
        }

        session.addInput(input)
        session.addOutput(output)

        self.session = session
        self.output = output
        self.completion = completion
        self.onStarted = onStarted
        destinationURL = destination
        didComplete = false

        NSLog("Markup: starting screen recording to \(destination.path)")

        session.startRunning()
        guard session.isRunning else {
            finish(.failure(MarkupError("Screen recording session did not start.")))
            return
        }

        output.startRecording(to: destination, recordingDelegate: self)

        let startTimeout = DispatchWorkItem { [weak self, weak output] in
            guard let self,
                  let currentOutput = self.output,
                  let output,
                  currentOutput === output,
                  !currentOutput.isRecording
            else {
                return
            }

            self.finish(.failure(MarkupError("Screen recording did not start. Check Screen Recording permission for Markup, relaunch the app, and try again.")))
        }
        startTimeoutWorkItem = startTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: startTimeout)

        let stopWorkItem = DispatchWorkItem { [weak self] in
            self?.output?.stopRecording()
        }
        self.stopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stopWorkItem)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        NSLog("Markup: screen recording started")
        startTimeoutWorkItem?.cancel()
        onStarted?()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error {
            NSLog("Markup: screen recording failed: \(error.localizedDescription)")
            finish(.failure(error))
        } else {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: outputFileURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else {
                    throw MarkupError("Screen recording finished but produced an empty movie.")
                }

                NSLog("Markup: screen recording finished, \(size) bytes")
                finish(.success(outputFileURL))
            } catch {
                NSLog("Markup: screen recording output could not be verified: \(error.localizedDescription)")
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !didComplete else { return }
        didComplete = true

        stopWorkItem?.cancel()
        stopWorkItem = nil
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil

        session?.stopRunning()
        session = nil
        output = nil
        destinationURL = nil
        onStarted = nil

        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

@available(macOS 15.0, *)
private final class ScreenCaptureKitRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let duration: TimeInterval
    private let destination: URL
    private let onStarted: (() -> Void)?
    private let completion: (Result<URL, Error>) -> Void
    private let workQueue = DispatchQueue(label: "dev.rikuwikman.markup.screen-capture-kit")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var stopWorkItem: DispatchWorkItem?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var finishTimeoutWorkItem: DispatchWorkItem?
    private var didStart = false
    private var didComplete = false

    init(
        duration: TimeInterval,
        onStarted: (() -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.duration = duration
        self.onStarted = onStarted
        self.completion = completion
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("markup-\(UUID().uuidString).mov")
        super.init()
    }

    func start() {
        Task {
            do {
                try await startScreenCaptureKitRecording()
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func startScreenCaptureKitRecording() async throws {
        NSLog("Markup: preparing ScreenCaptureKit recording to \(destination.path)")

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw MarkupError("No display is available for screen recording.")
        }

        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, CGDisplayPixelsWide(display.displayID))
        configuration.height = max(1, CGDisplayPixelsHigh(display.displayID))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.captureDynamicRange = .SDR

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = destination
        outputConfiguration.outputFileType = .mov
        outputConfiguration.videoCodecType = .h264

        let recordingOutput = SCRecordingOutput(
            configuration: outputConfiguration,
            delegate: self
        )

        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput

        let startTimeout = DispatchWorkItem { [weak self] in
            guard let self, !self.didStart else { return }
            self.finish(.failure(MarkupError("Screen recording did not start. Check Screen Recording permission for Markup, relaunch the app, and try again.")))
        }
        startTimeoutWorkItem = startTimeout

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        NSLog("Markup: ScreenCaptureKit stream started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: startTimeout)
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        NSLog("Markup: ScreenCaptureKit recording started")
        didStart = true
        startTimeoutWorkItem?.cancel()
        DispatchQueue.main.async {
            self.onStarted?()
        }

        let stopWorkItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        self.stopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: stopWorkItem)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("Markup: ScreenCaptureKit recording failed: \(error.localizedDescription)")
        finish(.failure(error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        NSLog("Markup: ScreenCaptureKit recording finished")
        verifyAndFinish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Markup: ScreenCaptureKit stream stopped with error: \(error.localizedDescription)")
        finish(.failure(error))
    }

    private func stopRecording() {
        guard let stream, let recordingOutput else {
            finish(.failure(MarkupError("Screen recording stream was not active.")))
            return
        }

        NSLog("Markup: stopping ScreenCaptureKit recording")
        do {
            try stream.removeRecordingOutput(recordingOutput)
        } catch {
            finish(.failure(error))
            return
        }

        let finishTimeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.verifyAndFinish()
        }
        finishTimeoutWorkItem = finishTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finishTimeout)
    }

    private func verifyAndFinish() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw MarkupError("Screen recording finished but produced an empty movie.")
            }

            NSLog("Markup: ScreenCaptureKit recording output verified, \(size) bytes")
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !didComplete else { return }
        didComplete = true

        stopWorkItem?.cancel()
        stopWorkItem = nil
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        finishTimeoutWorkItem?.cancel()
        finishTimeoutWorkItem = nil

        let stream = self.stream
        self.stream = nil
        recordingOutput = nil

        if stream != nil {
            stream?.stopCapture { error in
                if let error {
                    NSLog("Markup: ScreenCaptureKit stream stop reported: \(error.localizedDescription)")
                }
            }
        }

        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}
