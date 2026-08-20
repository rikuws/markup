import AppKit

/// In-flight dictation is drawn as a decode: glyphs flicker toward the
/// current hypothesis and lock once that character has been stable. Layout
/// is measured from the real target string so the host does not jitter.
final class DecodingTranscriptView: NSView {
    var onIntrinsicSizeInvalidated: (() -> Void)?

    var font = NSFont.systemFont(ofSize: 13, weight: .medium) {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var preferredMaxLayoutWidth: CGFloat = 320 {
        didSet {
            guard oldValue != preferredMaxLayoutWidth else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private(set) var committed = ""
    private(set) var volatile = ""

    private struct Slot {
        var target: Character
        var locked: Bool
        var targetSince: CFAbsoluteTime
    }

    private var slots: [Slot] = []
    private var displayedVolatile = ""
    private var indeterminateStatus: String?
    private var displayedIndeterminate = ""
    private var timer: Timer?
    private var accessibilityOptionsObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        accessibilityOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accessibilityDisplayOptionsDidChange()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        timer?.invalidate()
        if let accessibilityOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityOptionsObserver)
        }
    }

    func noteVisibilityChanged() {
        updateTimer()
    }

    override var isHidden: Bool {
        get { super.isHidden }
        set {
            super.isHidden = newValue
            updateTimer()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    override var intrinsicContentSize: NSSize {
        let trailing: String
        if let indeterminateStatus {
            trailing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? indeterminateStatus
                : Self.indeterminateLayoutSample
        } else {
            trailing = volatile
        }
        let text = Self.joined(committed, trailing)
        guard !text.isEmpty else { return .zero }
        let rect = NSAttributedString(string: text, attributes: Self.layoutAttributes(font: font))
            .boundingRect(
                with: NSSize(width: preferredMaxLayoutWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        return NSSize(width: min(preferredMaxLayoutWidth, ceil(rect.width)), height: ceil(rect.height) + 4)
    }

    func setTranscript(committed: String, volatile: String) {
        self.committed = committed
        self.volatile = volatile
        indeterminateStatus = nil
        displayedIndeterminate = ""
        retargetSlotsIfNeeded()
        render(now: CFAbsoluteTimeGetCurrent())
        invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
        updateTimer()
    }

    /// Shows capture/conversion activity before a batch engine has real words
    /// to offer. The glyphs are deliberately view-only and never enter the
    /// annotation model or accessibility value.
    func setIndeterminate(committed: String, status: String) {
        self.committed = committed
        volatile = ""
        slots = []
        displayedVolatile = ""
        indeterminateStatus = status
        render(now: CFAbsoluteTimeGetCurrent())
        invalidateIntrinsicContentSize()
        updateTimer()
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSMutableAttributedString()
        let committedAttrs = Self.layoutAttributes(font: font, color: NSColor.labelColor)
        let lockedAttrs = Self.layoutAttributes(font: font, color: NSColor.labelColor.withAlphaComponent(0.86))
        let unlockedAttrs = Self.layoutAttributes(font: font, color: NSColor.secondaryLabelColor)

        let trailing = indeterminateStatus == nil ? displayedVolatile : displayedIndeterminate
        if !committed.isEmpty {
            text.append(NSAttributedString(string: committed, attributes: committedAttrs))
            if !trailing.isEmpty {
                text.append(NSAttributedString(string: " ", attributes: committedAttrs))
            }
        }

        if indeterminateStatus != nil {
            text.append(NSAttributedString(string: trailing, attributes: unlockedAttrs))
        } else {
            for (index, character) in displayedVolatile.enumerated() {
                let locked = index < slots.count ? slots[index].locked : true
                text.append(NSAttributedString(
                    string: String(character),
                    attributes: locked ? lockedAttrs : unlockedAttrs
                ))
            }
        }

        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func retargetSlotsIfNeeded() {
        let target = Array(volatile)
        let now = CFAbsoluteTimeGetCurrent()
        var next: [Slot] = []
        next.reserveCapacity(target.count)
        for (index, character) in target.enumerated() {
            if index < slots.count, slots[index].target == character {
                next.append(slots[index])
            } else {
                let lockNow = !character.isLetter && !character.isNumber
                next.append(Slot(target: character, locked: lockNow, targetSince: now))
            }
        }
        slots = next
    }

    private func render(now: CFAbsoluteTime) {
        if let indeterminateStatus {
            displayedIndeterminate = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? indeterminateStatus
                : Self.randomPlaceholder()
            needsDisplay = true
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            displayedVolatile = volatile
            for index in slots.indices {
                slots[index].locked = true
            }
            needsDisplay = true
            return
        }

        var output = ""
        output.reserveCapacity(slots.count)
        for index in slots.indices {
            let slot = slots[index]
            if slot.locked {
                output.append(slot.target)
                continue
            }

            let settle = 0.08 + Double(index % 5) * 0.014
            let age = now - slot.targetSince
            if age >= settle {
                slots[index].locked = true
                output.append(slot.target)
                continue
            }

            let progress = min(1, age / settle)
            // Diffusion: the real glyph appears more often as the slot settles.
            if Double.random(in: 0..<1) < (progress * progress * 0.82 + 0.1) {
                output.append(slot.target)
            } else {
                output.append(Self.randomGlyph(matching: slot.target))
            }
        }
        displayedVolatile = output
        needsDisplay = true
    }

    private func updateTimer() {
        let shouldRun = window != nil
            && !isHiddenOrHasHiddenAncestor
            && (indeterminateStatus != nil || slots.contains(where: { !$0.locked }))
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if shouldRun {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: indeterminateStatus == nil ? 1.0 / 30.0 : 1.0 / 18.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.008
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func accessibilityDisplayOptionsDidChange() {
        timer?.invalidate()
        timer = nil
        render(now: CFAbsoluteTimeGetCurrent())
        invalidateIntrinsicContentSize()
        onIntrinsicSizeInvalidated?()
        updateTimer()
    }

    private func tick() {
        if isHiddenOrHasHiddenAncestor {
            timer?.invalidate()
            timer = nil
            return
        }
        render(now: CFAbsoluteTimeGetCurrent())
        if indeterminateStatus == nil, slots.allSatisfy(\.locked) {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func joined(_ leading: String, _ trailing: String) -> String {
        let left = leading.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    private static func layoutAttributes(font: NSFont, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]
        if let color {
            attributes[.foregroundColor] = color
        }
        return attributes
    }

    private static let lowerGlyphs = Array("aeiouyrtnslhcdmpbfgwkvxqz")
    private static let upperGlyphs = Array("AEIOUYRTNSLHCDMPBFGWKVXQZ")
    private static let digits = Array("0123456789")
    private static let indeterminateLayoutSample = "mmmmmm mmmmmmmm"

    private static func randomPlaceholder() -> String {
        let first = String((0..<6).map { _ in lowerGlyphs.randomElement() ?? "m" })
        let second = String((0..<8).map { _ in lowerGlyphs.randomElement() ?? "m" })
        return first + " " + second
    }

    private static func randomGlyph(matching target: Character) -> Character {
        if target.isNumber { return digits.randomElement() ?? target }
        if target.isUppercase { return upperGlyphs.randomElement() ?? target }
        if target.isLowercase { return lowerGlyphs.randomElement() ?? target }
        return target
    }
}
