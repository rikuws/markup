import AppKit
import SwiftUI

/// One transparent, full-screen view per display during a live session.
/// There is no screenshot and no dimmed chrome underneath — the desktop
/// stays live, and this view only carries the glass panes, caption chips,
/// and the drag interaction that creates new areas.
final class LiveSelectionView: NSView {
    weak var session: LiveMarkupSession?

    private final class AreaLayer {
        let tuning = SelectionGlassTuning()
        let pane: PassthroughHostingView<SelectionGlassPane>
        let stroke = ActiveAreaStrokeView()
        let chip = AreaChipView()
        var localRect: NSRect = .zero

        init() {
            pane = PassthroughHostingView(rootView: SelectionGlassPane(tuning: tuning))
            pane.sizingOptions = []
            pane.wantsLayer = true
            pane.clipsToBounds = false
            pane.layer?.masksToBounds = false
            pane.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private var layers: [UUID: AreaLayer] = [:]

    private let previewTuning = SelectionGlassTuning()
    private lazy var previewPane: PassthroughHostingView<SelectionGlassPane> = {
        let pane = PassthroughHostingView(rootView: SelectionGlassPane(tuning: previewTuning))
        pane.sizingOptions = []
        pane.wantsLayer = true
        pane.clipsToBounds = false
        pane.layer?.masksToBounds = false
        pane.layer?.backgroundColor = NSColor.clear.cgColor
        pane.isHidden = true
        return pane
    }()

    private let hintCapsule = PassthroughGlassView()
    private let hintLabel = NSTextField(labelWithString: "Drag anywhere to mark an area")
    private let listenCapsule = LiveListenCapsule()
    private var listenMode: LiveListenCapsule.Mode = .off

    private var dragStart: NSPoint?
    private var pressedAreaID: UUID?
    private var isDraggingSelection = false
    private var cursorTrackingArea: NSTrackingArea?
    private var selectionRect: NSRect? {
        didSet { updatePreviewPane() }
    }

    init(session: LiveMarkupSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = LiveSelectionWindow.hitTestFill.cgColor
        addSubview(previewPane)
        setupHintCapsule()
        setupListenCapsule()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        isDraggingSelection = false
        // Latest area wins when panes overlap.
        pressedAreaID = session?.draft.areas.reversed().first { area in
            layers[area.id]?.localRect.contains(point) == true
        }?.id
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }

        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingSelection {
            let distance = hypot(point.x - dragStart.x, point.y - dragStart.y)
            guard distance > 6 else { return }
            // A real drag always creates a new area, even when it started
            // on top of an existing one.
            pressedAreaID = nil
            isDraggingSelection = true
            session?.startNewAreaDrag()
        }

        let clamped = clamp(point, to: bounds)
        selectionRect = NSRect(
            x: min(dragStart.x, clamped.x),
            y: min(dragStart.y, clamped.y),
            width: abs(dragStart.x - clamped.x),
            height: abs(dragStart.y - clamped.y)
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            pressedAreaID = nil
            isDraggingSelection = false
            selectionRect = nil
        }

        let point = convert(event.locationInWindow, from: nil)
        let originPoint = dragStart ?? point

        if isDraggingSelection {
            guard let selectionRect, selectionRect.width >= 12, selectionRect.height >= 12 else {
                session?.abortNewAreaDrag()
                return
            }
            session?.commitSelection(
                localRect: selectionRect,
                in: self,
                originPoint: originPoint,
                releasePoint: point
            )
            return
        }

        if let pressedAreaID {
            session?.activateArea(id: pressedAreaID)
        }
    }

    // MARK: - Session-driven updates

    /// Rebuilds panes, strokes, and chips for the areas assigned to this
    /// view's screen. Called by the session whenever areas change.
    func reload(areas: [(area: MarkupArea, index: Int)], activeID: UUID?) {
        var seen = Set<UUID>()

        for entry in areas {
            let area = entry.area
            seen.insert(area.id)
            let layer = ensureLayer(for: area)
            let localRect = localRect(forGlobalCG: area.globalRect)
            layer.localRect = localRect
            layoutLayer(layer, area: area, index: entry.index, isActive: area.id == activeID)
        }

        for (id, layer) in layers where !seen.contains(id) {
            layer.pane.removeFromSuperview()
            layer.stroke.removeFromSuperview()
            layer.chip.removeFromSuperview()
            layers.removeValue(forKey: id)
        }

        layoutSessionChrome()
        window?.invalidateCursorRects(for: self)
    }

    /// Text-only refresh so live transcription does not rebuild layout or
    /// interrupt wave animations.
    func refreshChipTexts(areas: [(area: MarkupArea, index: Int)], activeID: UUID?) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        for entry in areas {
            guard let layer = layers[entry.area.id] else { continue }
            applyChipContent(layer.chip, area: entry.area, index: entry.index, isActive: entry.area.id == activeID)
            positionChip(layer)
        }
        NSAnimationContext.endGrouping()
    }

    func runWave(areaID: UUID, releasePoint: NSPoint?) {
        guard let layer = layers[areaID], !layer.pane.isHidden else { return }

        let localPoint = releasePoint ?? NSPoint(x: layer.localRect.midX, y: layer.localRect.minY)
        let panePoint = layer.pane.convert(localPoint, from: self)
        let origin = LiquidWaveShape.origin(
            nearestTo: panePoint,
            in: layer.pane.bounds,
            cornerRadius: layer.tuning.cornerRadius,
            pad: SelectionGlassTuning.wavePad
        )
        let shortest = max(
            1,
            min(layer.pane.bounds.width, layer.pane.bounds.height) - SelectionGlassTuning.wavePad * 2
        )
        let peak = min(9.5, shortest * 0.15, max(3.5, shortest * 0.055))
        layer.tuning.startWave(origin: origin, peak: peak)

        DispatchQueue.main.asyncAfter(deadline: .now() + SelectionGlassTuning.waveDuration + 0.12) { [weak layer] in
            layer?.tuning.endWaveIfNeeded()
        }
    }

    func endNoteEditing() {
        window?.makeFirstResponder(self)
    }

    // MARK: - Layers

    private func ensureLayer(for area: MarkupArea) -> AreaLayer {
        if let existing = layers[area.id] {
            return existing
        }

        let layer = AreaLayer()
        layers[area.id] = layer
        addSubview(layer.pane)
        addSubview(layer.stroke)
        addSubview(layer.chip)

        let id = area.id
        layer.chip.onActivate = { [weak self] in
            self?.session?.activateArea(id: id)
        }
        layer.chip.onDelete = { [weak self] in
            self?.session?.removeArea(id: id)
        }
        layer.chip.onNoteEdited = { [weak self] text in
            self?.session?.noteEdited(id: id, text: text)
        }
        layer.chip.onEditingChanged = { [weak self] isEditing in
            self?.session?.noteEditingChanged(id: id, isEditing: isEditing)
        }
        layer.chip.onSizeInvalidated = { [weak self, weak layer] in
            guard let self, let layer else { return }
            self.positionChip(layer)
        }
        return layer
    }

    private func layoutLayer(_ layer: AreaLayer, area: MarkupArea, index: Int, isActive: Bool) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        let selection = layer.localRect
        let cornerRadius = LiquidGlassSelectionRenderer.cornerRadius(
            shortest: min(selection.width, selection.height)
        )
        layer.pane.frame = selection.insetBy(
            dx: -SelectionGlassTuning.wavePad,
            dy: -SelectionGlassTuning.wavePad
        )
        if layer.tuning.cornerRadius != cornerRadius {
            layer.tuning.cornerRadius = cornerRadius
        }
        layer.pane.isHidden = false

        layer.stroke.cornerRadius = cornerRadius
        layer.stroke.frame = selection.insetBy(dx: -1.5, dy: -1.5)
        layer.stroke.isHidden = !isActive

        applyChipContent(layer.chip, area: area, index: index, isActive: isActive)
        positionChip(layer)

        NSAnimationContext.endGrouping()
    }

    private func applyChipContent(_ chip: AreaChipView, area: MarkupArea, index: Int, isActive: Bool) {
        chip.update(
            index: index,
            title: area.displayName,
            note: area.note,
            volatileNote: area.volatileNote,
            isActive: isActive,
            needsNote: !area.hasNote
        )
    }

    private func positionChip(_ layer: AreaLayer) {
        let selection = layer.localRect
        let width = min(max(selection.width, AreaChipView.minWidth), AreaChipView.maxWidth)
        let maxHeight = max(bounds.height - 16, AreaChipView.minHeight)
        let height = layer.chip.sizeThatFits(width: width, maxHeight: maxHeight).height
        applyChipFrame(layer, selection: selection, width: width, height: height)
        layer.chip.layoutContent()

        let synced = layer.chip.syncHeightToPlacedWidth(maxHeight: maxHeight)
        if abs(synced - height) > 0.5 {
            applyChipFrame(layer, selection: selection, width: width, height: synced)
            layer.chip.layoutContent()
        }
    }

    private func applyChipFrame(
        _ layer: AreaLayer,
        selection: NSRect,
        width: CGFloat,
        height: CGFloat
    ) {
        var x = selection.minX
        x = min(max(x, bounds.minX + 8), bounds.maxX - width - 8)

        // Below the area when there is room (Cocoa: below means smaller y),
        // else above, clamped to the screen.
        var y = selection.minY - height - 10
        if y < bounds.minY + 8 {
            y = min(selection.maxY + 10, bounds.maxY - height - 8)
        }

        layer.chip.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func localRect(forGlobalCG globalRect: CGRect) -> NSRect {
        guard let window else { return .zero }
        let cocoa = ScreenGeometry.cocoaRect(fromCG: globalRect)
        return convert(window.convertFromScreen(cocoa), from: nil)
    }

    func globalCGRect(forLocal rect: NSRect) -> CGRect {
        guard let window else { return .zero }
        let windowRect = convert(rect, to: nil)
        let cocoa = window.convertToScreen(windowRect)
        return ScreenGeometry.cgRect(fromCocoa: cocoa)
    }

    func globalCGPoint(forLocal point: NSPoint) -> CGPoint {
        guard let window else { return .zero }
        let windowPoint = convert(point, to: nil)
        let cocoa = window.convertPoint(toScreen: windowPoint)
        return ScreenGeometry.cgPoint(fromCocoa: cocoa)
    }

    // MARK: - Preview + hint

    private func updatePreviewPane() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        if let selection = selectionRect, selection.width >= 2, selection.height >= 2 {
            let cornerRadius = LiquidGlassSelectionRenderer.cornerRadius(
                shortest: min(selection.width, selection.height)
            )
            previewPane.frame = selection.insetBy(
                dx: -SelectionGlassTuning.wavePad,
                dy: -SelectionGlassTuning.wavePad
            )
            if previewTuning.cornerRadius != cornerRadius {
                previewTuning.cornerRadius = cornerRadius
            }
            previewPane.isHidden = false
            layoutSessionChrome()
        } else {
            previewPane.isHidden = true
            layoutSessionChrome()
        }

        NSAnimationContext.endGrouping()
    }

    private func setupHintCapsule() {
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = .labelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        hintCapsule.style = .regular
        hintCapsule.contentView = content
        hintCapsule.isHidden = false
        addSubview(hintCapsule)
    }

    private func setupListenCapsule() {
        listenCapsule.isHidden = true
        addSubview(listenCapsule)
    }

    func pushAudioLevel(_ level: Float) {
        listenCapsule.pushAudioLevel(level)
    }

    func updateListenFeedback(
        committed: String,
        volatile: String,
        mode: LiveListenCapsule.Mode,
        speechDetected: Bool
    ) {
        listenMode = mode
        listenCapsule.update(
            committed: committed,
            volatile: volatile,
            mode: mode,
            speechDetected: speechDetected
        )
        layoutSessionChrome()
    }

    override func layout() {
        super.layout()
        layoutSessionChrome()
    }

    /// Empty-state hint, or the live listen capsule before the first area
    /// and while a new area is being dragged (no caption chip yet).
    private func layoutSessionChrome() {
        let hasAreas = !(session?.draft.areas.isEmpty ?? true)
        let hasPreview = selectionRect.map { $0.width >= 2 && $0.height >= 2 } ?? false
        let followSelection = isDraggingSelection && hasPreview
        let showListen = listenMode != .off && (followSelection || !hasAreas)

        listenCapsule.isHidden = !showListen
        hintCapsule.isHidden = hasAreas || hasPreview || showListen

        if showListen {
            let maxWidth: CGFloat = 560
            listenCapsule.prepare(maxWidth: maxWidth)
            let intrinsic = listenCapsule.fittingSize
            let width = min(max(intrinsic.width, 200), maxWidth)
            listenCapsule.prepare(maxWidth: width)
            let size = listenCapsule.fittingSize
            let height = max(size.height, 40)
            let frame: NSRect
            if followSelection, let selection = selectionRect {
                frame = clampedFrame(width: width, height: height, under: selection)
            } else {
                frame = NSRect(
                    x: bounds.midX - width / 2,
                    y: bounds.midY - height / 2,
                    width: width,
                    height: height
                )
            }
            listenCapsule.frame = frame
            listenCapsule.cornerRadius = min(height / 2, 18)
        }

        if !hintCapsule.isHidden {
            let size = hintLabel.intrinsicContentSize
            let capsuleSize = NSSize(width: size.width + 34, height: size.height + 18)
            hintCapsule.frame = NSRect(
                x: bounds.midX - capsuleSize.width / 2,
                y: bounds.midY - capsuleSize.height / 2,
                width: capsuleSize.width,
                height: capsuleSize.height
            )
            hintCapsule.cornerRadius = capsuleSize.height / 2
        }
    }

    private func clampedFrame(width: CGFloat, height: CGFloat, under selection: NSRect) -> NSRect {
        var x = selection.midX - width / 2
        x = min(max(x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - width - 8))
        var y = selection.minY - height - 10
        if y < bounds.minY + 8 {
            y = min(selection.maxY + 10, bounds.maxY - height - 8)
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func clamp(_ point: NSPoint, to rect: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}

/// Accent hairline marking which area currently receives dictation.
final class ActiveAreaStrokeView: NSView {
    var cornerRadius: CGFloat = 8 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius + 1.5, yRadius: cornerRadius + 1.5)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// The caption chip attached to each area: index, owning app, and the
/// area's note. The note is an editable field, so notes can also be typed;
/// dictation writes into it while it is not being edited. Clicking the chip
/// retargets dictation to its area.
final class AreaChipView: NSGlassEffectView, NSTextFieldDelegate {
    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 560
    static let minHeight: CGFloat = 92

    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?
    var onNoteEdited: ((String) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    var onSizeInvalidated: (() -> Void)?

    private let indexBadge = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private let noteField = NSTextField()
    private let decodeView = DecodingTranscriptView()
    private let container = NSView()
    private let noteFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private var noteHeightConstraint: NSLayoutConstraint?
    private var isEditingNote = false
    private var isApplyingDisplay = false
    private var lastNote = ""
    private var lastVolatile = ""

    private static let horizontalInset: CGFloat = 14
    private static let verticalInset: CGFloat = 12

    init() {
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 14
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    // Swallow the click: NSView's default mouseDown would forward to the
    // selection view underneath and start a drag from under the chip.
    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    func update(
        index: Int,
        title: String,
        note: String,
        volatileNote: String,
        isActive: Bool,
        needsNote: Bool
    ) {
        indexBadge.stringValue = "\(index)"
        titleLabel.stringValue = title
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor

        let badgeColor: NSColor
        if isActive {
            badgeColor = .controlAccentColor
        } else if needsNote {
            badgeColor = NSColor.systemYellow.withAlphaComponent(0.9)
        } else {
            badgeColor = NSColor.gray.withAlphaComponent(0.65)
        }
        badgeContainer.layer?.backgroundColor = badgeColor.cgColor

        lastNote = note
        lastVolatile = volatileNote
        guard !isEditingNote else { return }
        applyNoteDisplay()
    }

    func layoutContent() {
        container.layoutSubtreeIfNeeded()
    }

    func sizeThatFits(width: CGFloat, maxHeight: CGFloat) -> NSSize {
        applyWrapWidth(max(width - Self.horizontalInset * 2, 1))
        refreshNoteHeight()
        container.layoutSubtreeIfNeeded()
        return NSSize(width: width, height: fittedHeight(maxHeight: maxHeight))
    }

    func syncHeightToPlacedWidth(maxHeight: CGFloat) -> CGFloat {
        let wrap = noteField.bounds.width
        guard wrap > 8 else {
            return fittedHeight(maxHeight: maxHeight)
        }
        applyWrapWidth(wrap)
        refreshNoteHeight()
        container.layoutSubtreeIfNeeded()
        return fittedHeight(maxHeight: maxHeight)
    }

    private func fittedHeight(maxHeight: CGFloat) -> CGFloat {
        var fitted = container.fittingSize.height + Self.verticalInset * 2
        if fitted > maxHeight, let constraint = noteHeightConstraint {
            constraint.constant = max(constraint.constant - (fitted - maxHeight), 20)
            container.layoutSubtreeIfNeeded()
            fitted = container.fittingSize.height + Self.verticalInset * 2
        }
        return min(max(fitted, Self.minHeight), maxHeight)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingNote = true
        decodeView.isHidden = true
        decodeView.setTranscript(committed: "", volatile: "")
        noteField.textColor = .labelColor
        noteField.stringValue = lastNote
        onEditingChanged?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditingNote = false
        onEditingChanged?(false)
        applyNoteDisplay()
        onSizeInvalidated?()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isApplyingDisplay else { return }
        lastNote = noteField.stringValue
        lastVolatile = ""
        onNoteEdited?(noteField.stringValue)
        onSizeInvalidated?()
    }

    private func applyNoteDisplay() {
        isApplyingDisplay = true
        defer { isApplyingDisplay = false }

        if isEditingNote {
            decodeView.isHidden = true
            decodeView.setTranscript(committed: "", volatile: "")
            noteField.textColor = .labelColor
            noteField.stringValue = lastNote
            refreshNoteHeight()
            return
        }

        if lastVolatile.isEmpty {
            decodeView.isHidden = true
            decodeView.setTranscript(committed: "", volatile: "")
            noteField.textColor = .labelColor
            noteField.stringValue = lastNote
            refreshNoteHeight()
            return
        }

        let combined = displayedNoteText
        noteField.stringValue = combined
        noteField.textColor = .clear
        decodeView.isHidden = false
        decodeView.setTranscript(committed: lastNote, volatile: lastVolatile)
        refreshNoteHeight()
    }

    private var displayedNoteText: String {
        [lastNote, lastVolatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func applyWrapWidth(_ textWidth: CGFloat) {
        if noteField.preferredMaxLayoutWidth != textWidth {
            noteField.preferredMaxLayoutWidth = textWidth
        }
        decodeView.preferredMaxLayoutWidth = textWidth
    }

    private func refreshNoteHeight() {
        let text = displayedNoteText
        let sample = text.isEmpty ? (noteField.placeholderString ?? " ") : text
        let wrap = max(noteField.preferredMaxLayoutWidth, 1)
        let cellHeight = noteField.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: wrap, height: 10_000)
        ).height ?? 0
        let measured = max(ceil(cellHeight), Self.height(of: sample, font: noteFont, width: wrap))
        let line = ceil(noteFont.ascender - noteFont.descender + noteFont.leading)
        let minNote = max(line * 2, 40)
        noteHeightConstraint?.constant = max(measured, minNote)
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let rect = NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: style]
        )
            .boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        return ceil(rect.height) + 4
    }

    private func setup() {
        indexBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        indexBadge.textColor = .white
        indexBadge.alignment = .center
        indexBadge.translatesAutoresizingMaskIntoConstraints = false

        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.cornerRadius = 9
        badgeContainer.addSubview(indexBadge)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove area")
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .inline
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [badgeContainer, titleLabel, NSView(), deleteButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        noteField.placeholderString = "Say or type what should change…"
        noteField.font = noteFont
        noteField.isBordered = false
        noteField.drawsBackground = false
        noteField.focusRingType = .none
        noteField.lineBreakMode = .byWordWrapping
        noteField.usesSingleLineMode = false
        noteField.maximumNumberOfLines = 0
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        (noteField.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = false
        noteField.preferredMaxLayoutWidth = Self.maxWidth - Self.horizontalInset * 2
        noteField.setContentHuggingPriority(.required, for: .vertical)
        noteField.setContentCompressionResistancePriority(.required, for: .vertical)
        noteField.delegate = self

        decodeView.font = noteFont
        decodeView.preferredMaxLayoutWidth = noteField.preferredMaxLayoutWidth
        decodeView.isHidden = true

        let height = noteField.heightAnchor.constraint(equalToConstant: 36)
        height.priority = .required
        noteHeightConstraint = height

        let stack = NSStackView(views: [header, noteField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.addSubview(decodeView)

        NSLayoutConstraint.activate([
            indexBadge.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            indexBadge.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            badgeContainer.widthAnchor.constraint(equalToConstant: 22),
            badgeContainer.heightAnchor.constraint(equalToConstant: 18),
            height,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            noteField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            noteField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            decodeView.leadingAnchor.constraint(equalTo: noteField.leadingAnchor),
            decodeView.trailingAnchor.constraint(equalTo: noteField.trailingAnchor),
            decodeView.topAnchor.constraint(equalTo: noteField.topAnchor),
            decodeView.bottomAnchor.constraint(equalTo: noteField.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])

        let content = NSView()
        content.autoresizingMask = [.width, .height]
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.horizontalInset),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.horizontalInset),
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.verticalInset),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.verticalInset)
        ])
        contentView = content
        refreshNoteHeight()
    }

    @objc private func deleteClicked() {
        onDelete?()
    }
}

/// The floating session bar: listening chip, hints, Cancel, and Save.
/// There is no editor window in 2.0, so this is all the chrome a session
/// has.
final class SessionHUDView: NSGlassEffectView {
    var onToggleListening: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    let listeningChip = ListeningChipButton()
    private let hintLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 14
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    // Keep clicks on the bar from reaching the selection view underneath.
    override func mouseDown(with event: NSEvent) {}

    func update(areaCount: Int, canSave: Bool, isListening: Bool) {
        saveButton.isEnabled = canSave
        if areaCount == 0 {
            hintLabel.stringValue = "Drag to mark an area"
        } else if isListening {
            hintLabel.stringValue = "\(areaCount) area\(areaCount == 1 ? "" : "s") · Esc mutes · Return saves"
        } else {
            hintLabel.stringValue = "\(areaCount) area\(areaCount == 1 ? "" : "s") · Esc cancels · Return saves"
        }
    }

    private func setup() {
        listeningChip.target = self
        listeningChip.action = #selector(listeningClicked)

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.contentTintColor = .controlAccentColor
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        let stack = NSStackView(views: [listeningChip, hintLabel, NSView(), cancelButton, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
        contentView = content
    }

    @objc private func listeningClicked() {
        onToggleListening?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    @objc private func saveClicked() {
        onSave?()
    }
}

final class ListeningChipButton: NSControl {
    enum Mode {
        case hidden
        case preparing
        case listening
        case muted
        case unavailable
    }

    var mode: Mode = .hidden {
        didSet {
            guard oldValue != mode else { return }
            applyMode()
        }
    }

    var speechDetected = false {
        didSet {
            guard oldValue != speechDetected else { return }
            updateListeningBackground()
        }
    }

    private let iconView = NSImageView()
    private let meter = VoiceMeterView(barCount: 14, barColor: NSColor.white.withAlphaComponent(0.95))
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.button)

        iconView.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byClipping
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        meter.setContentHuggingPriority(.required, for: .horizontal)
        meter.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            meter.widthAnchor.constraint(equalToConstant: 46),
            meter.heightAnchor.constraint(equalToConstant: 14)
        ])

        let content = NSStackView(views: [iconView, meter, titleLabel])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.detachesHiddenViews = true
        content.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addSubview(content)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyMode()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let meterWidth: CGFloat = mode == .listening ? 46 + 4 : 0
        return NSSize(width: max(8 + 12 + 4 + meterWidth + titleWidth + 8, 88), height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && bounds.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }

    func pushAudioLevel(_ level: Float) {
        guard mode == .listening else { return }
        meter.push(level: level, speechDetected: speechDetected)
    }

    private func applyMode() {
        isHidden = mode == .hidden
        isEnabled = mode != .preparing
        meter.reset()
        meter.isHidden = mode != .listening

        switch mode {
        case .hidden:
            titleLabel.stringValue = ""
            iconView.image = nil
            toolTip = nil
            setAccessibilityLabel(nil)
            layer?.backgroundColor = NSColor.clear.cgColor
        case .preparing:
            titleLabel.stringValue = "Preparing"
            iconView.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
            toolTip = "Preparing on-device dictation"
            setAccessibilityLabel("Preparing")
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        case .listening:
            titleLabel.stringValue = "Listening"
            iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
            toolTip = "Click to mute. Escape also mutes."
            setAccessibilityLabel("Listening")
        case .muted:
            titleLabel.stringValue = "Muted"
            iconView.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)
            toolTip = "Click to talk while you mark"
            setAccessibilityLabel("Muted")
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        case .unavailable:
            titleLabel.stringValue = "Mic off"
            iconView.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)
            toolTip = "Microphone permission is needed for talk-while-you-mark notes"
            setAccessibilityLabel("Mic off")
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.55).cgColor
        }

        updateListeningBackground()
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private func updateListeningBackground() {
        guard mode == .listening else { return }
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(speechDetected ? 0.92 : 0.72).cgColor
    }
}
