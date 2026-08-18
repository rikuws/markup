import AppKit

/// A scrolling, center-mirrored bar meter driven by live microphone RMS.
/// Resting bars are a faint spine so the control reads as on; speech
/// stretches them. Newest samples sit on the right.
final class VoiceMeterView: NSView {
    private let barCount: Int
    private var samples: [CGFloat]
    var barColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(barCount: Int, barColor: NSColor) {
        self.barCount = max(4, barCount)
        self.samples = Array(repeating: 0, count: max(4, barCount))
        self.barColor = barColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(barCount) * 3.2, height: 16)
    }

    func push(level: Float, speechDetected: Bool) {
        let floor: CGFloat = speechDetected ? 0.18 : 0
        let value = max(CGFloat(level), floor)
        samples.append(min(1, value))
        if samples.count > barCount {
            samples.removeFirst(samples.count - barCount)
        }
        needsDisplay = true
    }

    func reset() {
        samples = Array(repeating: 0, count: barCount)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard barCount > 0, bounds.width > 1, bounds.height > 1 else { return }

        let spacing = max(1, min(2.25, bounds.width / CGFloat(barCount) * 0.3))
        let barWidth = max(1.6, (bounds.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        let midY = bounds.midY
        let radius = barWidth / 2

        for index in 0..<barCount {
            let sample = index < samples.count ? samples[index] : 0
            let amplitude = max(0.1, min(1, sample))
            let height = max(2, amplitude * bounds.height)
            let x = bounds.minX + CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            barColor.withAlphaComponent(0.3 + 0.7 * amplitude).setFill()
            path.fill()
        }
    }
}
