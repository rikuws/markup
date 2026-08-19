import Combine
import FluidAudio
import Foundation

/// On-disk and download state for Parakeet TDT 0.6B v3, shown in Settings.
@MainActor
final class ParakeetModelStatus: ObservableObject {
    static let shared = ParakeetModelStatus()

    enum Phase: Equatable {
        case checking
        case notDownloaded
        case downloading(fraction: Double, detail: String)
        case compiling(String)
        case ready
        case damaged(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .checking

    private var prepareTask: Task<Void, Never>?

    func refreshFromDisk() {
        guard prepareTask == nil else { return }
        if ParakeetTranscriptionEngine.modelsAreOnDisk() {
            if case .damaged = phase { return }
            if case .failed = phase { return }
            phase = .ready
        } else {
            phase = .notDownloaded
        }
    }

    /// Download (if needed) and load Parakeet immediately. Safe to call from
    /// Settings when the engine is turned on, and on launch if it already is.
    func ensureDownloaded(forceRedownload: Bool = false) {
        if prepareTask != nil, !forceRedownload { return }

        let onDisk = ParakeetTranscriptionEngine.modelsAreOnDisk()
        if forceRedownload {
            phase = .downloading(fraction: 0, detail: "Downloading Parakeet…")
        } else if onDisk {
            phase = .ready
        } else {
            phase = .downloading(fraction: 0, detail: "Downloading Parakeet…")
        }

        prepareTask?.cancel()
        prepareTask = Task { [onDisk] in
            do {
                try await ParakeetTranscriptionEngine.shared.prepare(forceRedownload: forceRedownload)
                guard !Task.isCancelled else { return }
                self.phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                NSLog("Markup: Parakeet prepare failed: %@", message)
                if onDisk, !forceRedownload {
                    self.phase = .damaged("Parakeet files are present but failed to load.")
                } else {
                    self.phase = .failed(message)
                }
            }
            self.prepareTask = nil
        }
    }

    func redownload() {
        ensureDownloaded(forceRedownload: true)
    }

    func handleDownloadProgress(_ progress: DownloadProgress) {
        if case .ready = phase { return }

        switch progress.phase {
        case .listing:
            phase = .downloading(
                fraction: progress.fractionCompleted,
                detail: "Finding Parakeet files…"
            )
        case .downloading(let completed, let total):
            let detail: String
            if total > 0 {
                detail = "Downloading Parakeet (\(completed)/\(total))"
            } else {
                detail = "Downloading Parakeet…"
            }
            phase = .downloading(fraction: progress.fractionCompleted, detail: detail)
        case .compiling(let modelName):
            phase = .compiling("Preparing \(modelName)…")
        }
    }
}
