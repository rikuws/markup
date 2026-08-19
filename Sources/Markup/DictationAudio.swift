import AVFoundation
import Accelerate
import Darwin
import Foundation

enum DictationAudioFormat {
    static let parakeetSampleRate: Double = 16_000

    static func parakeetFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: parakeetSampleRate,
            channels: 1,
            interleaved: false
        )
    }

    static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return [] }

        let channelCount = Int(buffer.format.channelCount)
        if channelCount <= 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        var mixed = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channelCount)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for frame in 0..<frames {
                mixed[frame] += pointer[frame] * scale
            }
        }
        return mixed
    }

    static func pcmBuffer(from audio: CapturedAudio) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        let frames = AVAudioFrameCount(audio.samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard let destination = buffer.floatChannelData?[0] else { return nil }
        audio.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            memcpy(destination, base, source.count * MemoryLayout<Float>.stride)
        }
        return buffer
    }
}

final class PCMBufferConverter {
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

/// Collects 16 kHz mono Float32 samples from the mic tap for batch ASR.
final class PCMSampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var converter: PCMBufferConverter?

    init?(from inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        if DictationAudioFormat.formatsMatch(inputFormat, outputFormat) {
            converter = nil
        } else if let prepared = PCMBufferConverter(from: inputFormat, to: outputFormat) {
            converter = prepared
        } else {
            return nil
        }
        samples.reserveCapacity(Int(outputFormat.sampleRate * 8))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let converted: AVAudioPCMBuffer?
        if let converter {
            converted = converter.convert(buffer)
        } else {
            converted = DictationAudioFormat.copyPCMBuffer(buffer)
        }
        guard let converted else { return }
        samples.append(contentsOf: DictationAudioFormat.floatSamples(from: converted))
    }

    func take() -> CapturedAudio {
        lock.lock()
        defer { lock.unlock() }
        if converter != nil {
            // `AVAudioConverter` cannot convert after `.endOfStream`. Recreate
            // it so later areas keep receiving resampled mic audio.
            if let converter {
                for leftover in converter.drain() {
                    samples.append(contentsOf: DictationAudioFormat.floatSamples(from: leftover))
                }
            }
            if let refreshed = PCMBufferConverter(from: inputFormat, to: outputFormat) {
                converter = refreshed
            }
        }
        let taken = samples
        samples = []
        samples.reserveCapacity(taken.capacity)
        return CapturedAudio(samples: taken, sampleRate: outputFormat.sampleRate)
    }
}

/// RMS/peak from the mic tap, published on the main queue at ~50 Hz.
final class AudioLevelSink: @unchecked Sendable {
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

enum PCMAmplitude {
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
