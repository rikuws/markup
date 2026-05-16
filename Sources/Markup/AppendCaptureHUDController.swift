import AppKit

final class AppendCaptureHUDController: NSWindowController {
    init(shotIndex: Int, hotKeyDisplay: String) {
        let contentView = AppendCaptureHUDView(
            title: "Adding Shot \(shotIndex) to previous feedback",
            detail: "Arrange the app, then press \(hotKeyDisplay)."
        )
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let x = visibleFrame.midX - window.frame.width / 2
        let y = visibleFrame.maxY - window.frame.height - 36
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFrontRegardless()
    }
}

private final class AppendCaptureHUDView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 96))
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 18,
            cornerHeight: 18,
            transform: nil
        )
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 20
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.masksToBounds = true

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.86).cgColor
        tintView.layer?.cornerRadius = 18
        tintView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        tintView.layer?.borderWidth = 0.5
        tintView.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 23, weight: .semibold)
        icon.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        detailLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        let content = NSStackView(views: [icon, labels])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 14

        addSubview(effectView)
        addSubview(tintView, positioned: .above, relativeTo: effectView)
        addSubview(content, positioned: .above, relativeTo: tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
}
