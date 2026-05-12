import AppKit

final class AnnotationWindowController: NSWindowController {
    private let viewController: AnnotationViewController

    init(
        captured: CapturedWindow,
        recordingURL: URL?,
        onSave: @escaping (String, CaptureRegion, NSImage, NSImage, URL?) -> Void,
        onCancel: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) {
        viewController = AnnotationViewController(
            captured: captured,
            recordingURL: recordingURL,
            onSave: onSave,
            onCancel: onCancel,
            onRecord: onRecord
        )

        let screenFrame = NSScreen.allScreenFrame
        let window = AnnotationOverlayWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.onEscape = { [weak viewController] in
            viewController?.cancelAnnotation()
        }

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSLog("punchlist: showing annotation editor")
        NSApp.activate(ignoringOtherApps: true)
        window?.setFrame(NSScreen.allScreenFrame, display: true)
        window?.orderFrontRegardless()
        window?.makeKey()
        window?.makeFirstResponder(viewController.initialFirstResponder)
    }
}

final class AnnotationOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onEscape?()
            return
        }

        super.sendEvent(event)
    }
}

final class AnnotationViewController: NSViewController, NSTextViewDelegate {
    private let captured: CapturedWindow
    private let recordingURL: URL?
    private let onSave: (String, CaptureRegion, NSImage, NSImage, URL?) -> Void
    private let onCancel: () -> Void
    private let onRecord: () -> Void

    private let canvas: AnnotationCanvasView
    private let noteTextView = NSTextView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let recordingBadge = NSTextField(labelWithString: "")

    var initialFirstResponder: NSResponder {
        canvas
    }

    init(
        captured: CapturedWindow,
        recordingURL: URL?,
        onSave: @escaping (String, CaptureRegion, NSImage, NSImage, URL?) -> Void,
        onCancel: @escaping () -> Void,
        onRecord: @escaping () -> Void
    ) {
        self.captured = captured
        self.recordingURL = recordingURL
        self.onSave = onSave
        self.onCancel = onCancel
        self.onRecord = onRecord
        canvas = AnnotationCanvasView(image: captured.image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        canvas.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.updateSaveState()
            if self.canvas.captureRegion != nil {
                self.view.window?.makeFirstResponder(self.noteTextView)
            }
        }
        noteTextView.delegate = self
        updateSaveState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
    }

    func textDidChange(_ notification: Notification) {
        updateSaveState()
    }

    private func buildLayout() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 14
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let header = NSTextField(labelWithString: "\(captured.appName) - \(captured.windowTitle)")
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.textColor = .white
        header.lineBreakMode = .byTruncatingMiddle

        let helperText = recordingURL == nil
            ? "Drag one box around the issue, then write the instruction for the coding agent."
            : "Recording attached. Drag one box, add a note, then Save to write the feedback folder."
        let helper = NSTextField(labelWithString: helperText)
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = NSColor.white.withAlphaComponent(0.82)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let noteGlass = LiquidGlassNoteView()
        noteGlass.translatesAutoresizingMaskIntoConstraints = false

        let noteScroll = NSScrollView()
        noteScroll.translatesAutoresizingMaskIntoConstraints = false
        noteScroll.hasVerticalScroller = true
        noteScroll.hasHorizontalScroller = false
        noteScroll.autohidesScrollers = true
        noteScroll.borderType = .noBorder
        noteScroll.focusRingType = .none
        noteScroll.drawsBackground = false
        noteScroll.scrollerStyle = .overlay
        noteScroll.contentView.drawsBackground = false
        noteScroll.documentView = noteTextView
        noteTextView.frame = NSRect(x: 0, y: 0, width: 640, height: 160)
        noteTextView.minSize = NSSize(width: 0, height: 160)
        noteTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.autoresizingMask = [.width]
        noteTextView.textContainer?.containerSize = NSSize(
            width: noteTextView.bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        noteTextView.textContainer?.widthTracksTextView = true
        noteTextView.font = .systemFont(ofSize: 16)
        noteTextView.textColor = .white
        noteTextView.insertionPointColor = .white
        noteTextView.focusRingType = .none
        noteTextView.drawsBackground = false
        noteTextView.backgroundColor = .clear
        noteTextView.textContainerInset = NSSize(width: 20, height: 18)
        noteTextView.textContainer?.lineFragmentPadding = 0
        noteTextView.isRichText = false
        noteTextView.allowsUndo = true
        noteTextView.string = ""
        noteGlass.installContentView(noteScroll)

        let noteLabel = NSTextField(labelWithString: "Note")
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        noteLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let recordButton = NSButton(title: "Record 10s", target: self, action: #selector(recordSelected))
        recordButton.bezelStyle = .rounded
        recordButton.isEnabled = recordingURL == nil

        recordingBadge.stringValue = recordingURL == nil ? "" : "Recording attached - Save to write folder"
        recordingBadge.textColor = .systemGreen
        recordingBadge.font = .systemFont(ofSize: 12, weight: .semibold)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSelected))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        saveButton.target = self
        saveButton.action = #selector(saveSelected)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let actions = NSStackView(views: [recordButton, recordingBadge, NSView(), cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        actions.distribution = .fill

        let noteSection = NSView()
        noteSection.translatesAutoresizingMaskIntoConstraints = false
        noteSection.addSubview(noteLabel)
        noteSection.addSubview(noteGlass)

        container.addArrangedSubview(header)
        container.addArrangedSubview(helper)
        container.addArrangedSubview(canvas)
        container.addArrangedSubview(noteSection)
        container.addArrangedSubview(actions)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            noteLabel.topAnchor.constraint(equalTo: noteSection.topAnchor),
            noteLabel.centerXAnchor.constraint(equalTo: noteSection.centerXAnchor),
            noteGlass.leadingAnchor.constraint(equalTo: noteSection.leadingAnchor),
            noteGlass.trailingAnchor.constraint(equalTo: noteSection.trailingAnchor),
            noteGlass.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            noteGlass.bottomAnchor.constraint(equalTo: noteSection.bottomAnchor),
            noteGlass.heightAnchor.constraint(equalToConstant: 184)
        ])
    }

    @objc private func saveSelected() {
        guard let region = canvas.captureRegion else {
            NSSound.beep()
            return
        }

        let note = noteTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(noteTextView)
            return
        }

        guard let annotated = ScreenshotAnnotator.annotatedImage(source: captured.image, region: region) else {
            NSSound.beep()
            return
        }

        onSave(note, region, annotated, captured.image, recordingURL)
    }

    @objc private func cancelSelected() {
        cancelAnnotation()
    }

    func cancelAnnotation() {
        onCancel()
        view.window?.close()
    }

    @objc private func recordSelected() {
        onRecord()
    }

    private func updateSaveState() {
        let note = noteTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = canvas.captureRegion != nil && !note.isEmpty
    }
}

final class LiquidGlassNoteView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let strokeView = LiquidGlassStrokeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func installContentView(_ contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView, positioned: .above, relativeTo: tintView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        addSubview(strokeView, positioned: .above, relativeTo: contentView)
        NSLayoutConstraint.activate([
            strokeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            strokeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            strokeView.topAnchor.constraint(equalTo: topAnchor),
            strokeView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: 20,
            cornerHeight: 20,
            transform: nil
        )
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 20
        effectView.layer?.masksToBounds = true

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        tintView.layer?.cornerRadius = 20
        tintView.layer?.masksToBounds = true

        strokeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effectView)
        addSubview(tintView, positioned: .above, relativeTo: effectView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class LiquidGlassStrokeView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let outerRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let outer = NSBezierPath(roundedRect: outerRect, xRadius: 20, yRadius: 20)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        outer.lineWidth = 1.5
        outer.stroke()

        let innerRect = bounds.insetBy(dx: 2.25, dy: 2.25)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: 18, yRadius: 18)
        NSColor.black.withAlphaComponent(0.28).setStroke()
        inner.lineWidth = 1
        inner.stroke()
    }
}

private extension NSScreen {
    static var allScreenFrame: NSRect {
        let frames = screens.map(\.frame)
        guard let first = frames.first else {
            return NSRect(x: 0, y: 0, width: 1280, height: 800)
        }

        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
