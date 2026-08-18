import AppKit

/// Glass listen HUD used when there is no caption chip: before the first
/// area, and while a new area is being dragged. A live waveform proves
/// the mic is hearing the user; decoding text shows the in-flight note.
final class LiveListenCapsule: NSGlassEffectView {
    enum Mode {
        case off
        case preparing
        case listening
    }

    private let meter = VoiceMeterView(barCount: 28, barColor: .controlAccentColor)
    private let decodeView = DecodingTranscriptView()
    private let fallbackLabel = NSTextField(labelWithString: "Listening")
    private let container = NSView()
    private var speechDetected = false
    private var mode: Mode = .off

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 18
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            super.isHidden = newValue
            decodeView.noteVisibilityChanged()
        }
    }

    override var fittingSize: NSSize {
        container.layoutSubtreeIfNeeded()
        let size = container.fittingSize
        return NSSize(width: size.width + 28, height: size.height + 20)
    }

    func update(
        committed: String,
        volatile: String,
        mode: Mode,
        speechDetected: Bool
    ) {
        self.mode = mode
        self.speechDetected = speechDetected
        if mode != .listening {
            meter.reset()
        }

        let showText = !committed.isEmpty || !volatile.isEmpty
        decodeView.isHidden = !showText
        fallbackLabel.isHidden = showText

        if showText {
            decodeView.setTranscript(committed: committed, volatile: volatile)
        } else {
            decodeView.setTranscript(committed: "", volatile: "")
            fallbackLabel.stringValue = mode == .preparing ? "Preparing" : "Listening"
        }

        let spoken = [committed, volatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let status = showText ? spoken : fallbackLabel.stringValue
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(status)

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func pushAudioLevel(_ level: Float) {
        guard mode == .listening else { return }
        meter.push(level: level, speechDetected: speechDetected)
    }

    private func setup() {
        meter.setContentHuggingPriority(.required, for: .horizontal)
        meter.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            meter.widthAnchor.constraint(equalToConstant: 84),
            meter.heightAnchor.constraint(equalToConstant: 22)
        ])

        fallbackLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fallbackLabel.textColor = .secondaryLabelColor
        fallbackLabel.setContentHuggingPriority(.required, for: .horizontal)

        decodeView.font = .systemFont(ofSize: 13, weight: .medium)
        decodeView.preferredMaxLayoutWidth = 320
        decodeView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [meter, fallbackLabel, decodeView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let content = NSView()
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        contentView = content

        decodeView.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Listening")
    }
}
