import AppKit

final class RecordingProgressWindowController: NSWindowController {
    private let duration: TimeInterval
    private let stopShortcutDisplay: String
    private let titleLabel = NSTextField(labelWithString: "Starting recording...")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private var timer: Timer?
    private var startedAt: Date?

    init(duration: TimeInterval, stopShortcutDisplay: String) {
        self.duration = duration
        self.stopShortcutDisplay = stopShortcutDisplay

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 128))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        detailLabel.stringValue = "Press \(stopShortcutDisplay) again to stop early."
        detailLabel.lineBreakMode = .byWordWrapping

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = duration
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .small

        content.addSubview(dot)
        content.addSubview(titleLabel)
        content.addSubview(detailLabel)
        content.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            dot.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            titleLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),

            progressIndicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            progressIndicator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            progressIndicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])

        let panel = NSPanel(
            contentRect: content.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none

        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSLog("Markup: showing recording progress window")
        positionNearTopRight()
        window?.orderFrontRegardless()
    }

    func markStarted() {
        startedAt = Date()
        tick()

        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func markStopping() {
        timer?.invalidate()
        timer = nil

        if let startedAt {
            progressIndicator.doubleValue = min(duration, Date().timeIntervalSince(startedAt))
        }
        titleLabel.stringValue = "Stopping recording..."
        detailLabel.stringValue = "The editor will reopen when the clip is ready."
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    private func tick() {
        guard let startedAt else { return }

        let elapsed = min(duration, Date().timeIntervalSince(startedAt))
        let remaining = max(0, Int(ceil(duration - elapsed)))
        titleLabel.stringValue = "Recording \(remaining)s"
        progressIndicator.doubleValue = elapsed
    }

    private func positionNearTopRight() {
        guard let window else { return }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: screenFrame.maxX - window.frame.width - margin,
            y: screenFrame.maxY - window.frame.height - margin
        )
        window.setFrameOrigin(origin)
    }
}
