import AppKit
import Combine
import SwiftUI

final class TopNotchController {
    private let settingsStore: SettingsStore
    private let feedbackInbox = FeedbackInbox()
    private let model = TopNotchModel()

    private var panel: NSPanel?
    private var settingsCancellable: AnyCancellable?
    private var screenCancellable: AnyCancellable?
    private var refreshTimer: Timer?
    private var screenFollowTimer: Timer?
    private var collapseWorkItem: DispatchWorkItem?
    private var contentRevealWorkItem: DispatchWorkItem?
    private var frameCollapseWorkItem: DispatchWorkItem?
    private var chromeCollapseWorkItem: DispatchWorkItem?
    private var currentScreenID: CGDirectDisplayID?
    private var expandedHoverFrame: NSRect?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore

        model.onHoverChanged = { [weak self] isHovering in
            self?.setHovering(isHovering)
        }
        model.openScreenshot = { feedback in
            guard let screenshotURL = feedback.screenshotURL else { return }
            NSWorkspace.shared.open(screenshotURL)
        }
        model.revealFeedback = { feedback in
            NSWorkspace.shared.activateFileViewerSelecting([feedback.directoryURL])
        }
        model.saveFeedbackNote = { [weak self] feedback, note in
            self?.saveFeedbackNote(feedback, note: note)
        }
        model.deleteFeedback = { [weak self] feedback in
            self?.deleteFeedback(feedback)
        }
        model.layoutInvalidated = { [weak self] in
            guard let self, self.model.isExpanded else { return }
            self.positionPanel(animated: true)
        }
    }

    deinit {
        refreshTimer?.invalidate()
        screenFollowTimer?.invalidate()
    }

    func start() {
        settingsCancellable = settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.apply(settings)
            }

        screenCancellable = NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.positionPanel(animated: false)
        }

        apply(settingsStore.settings)
    }

    private func apply(_ settings: MarkupSettings) {
        guard settings.topNotchEnabled else {
            closePanel()
            return
        }

        ensurePanel()
        refreshSnapshot()
        positionPanel(animated: false)
        panel?.orderFrontRegardless()
        restartRefreshTimer()
        restartScreenFollowTimer()
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let initialSize = TopNotchConstants.builtInIdleSize
        let contentView = NSHostingView(rootView: TopNotchPanelView(model: model))
        contentView.frame = NSRect(origin: .zero, size: initialSize)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = TopNotchPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.level = NSWindow.Level.statusBar
        panel.collectionBehavior = NSWindow.CollectionBehavior([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ])
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = NSWindow.AnimationBehavior.none
        panel.ignoresMouseEvents = false

        self.panel = panel
    }

    private func closePanel() {
        collapseWorkItem?.cancel()
        contentRevealWorkItem?.cancel()
        frameCollapseWorkItem?.cancel()
        chromeCollapseWorkItem?.cancel()
        refreshTimer?.invalidate()
        screenFollowTimer?.invalidate()
        refreshTimer = nil
        screenFollowTimer = nil
        model.isExpanded = false
        model.showsExpandedContent = false
        model.showsExpandedChrome = false
        model.expandedProjectID = nil
        model.editingFeedbackID = nil
        expandedHoverFrame = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func setHovering(_ isHovering: Bool) {
        if isHovering {
            collapseWorkItem?.cancel()
            setExpanded(true)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isMouseInsideStableHoverArea() {
                return
            }
            if self.model.editingFeedbackID != nil {
                return
            }
            self.setExpanded(false)
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func setExpanded(_ isExpanded: Bool) {
        contentRevealWorkItem?.cancel()
        frameCollapseWorkItem?.cancel()
        chromeCollapseWorkItem?.cancel()

        guard model.isExpanded != isExpanded else {
            if isExpanded {
                model.showsExpandedChrome = true
                refreshSnapshot()
                revealExpandedContent(after: 0.02)
            }
            return
        }

        if isExpanded {
            refreshSnapshot()
            model.showsExpandedChrome = true
            model.isExpanded = true
            positionPanel(animated: true)
            revealExpandedContent(after: TopNotchConstants.contentRevealDelay)
        } else {
            model.showsExpandedContent = false
            scheduleFrameCollapse()
        }
        restartRefreshTimer()
    }

    private func revealExpandedContent(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.model.showsExpandedContent = true
        }
        contentRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleFrameCollapse() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.isExpanded = false
            self.positionPanel(animated: true)
            self.restartRefreshTimer()
            self.scheduleChromeCollapse()
        }
        frameCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TopNotchConstants.contentFadeOutDelay, execute: workItem)
    }

    private func scheduleChromeCollapse() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.model.isExpanded, !self.model.showsExpandedContent else { return }
            self.model.showsExpandedChrome = false
            self.model.expandedProjectID = nil
            self.model.editingFeedbackID = nil
            self.expandedHoverFrame = nil
        }
        chromeCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TopNotchConstants.collapseDuration, execute: workItem)
    }

    private func refreshSnapshot() {
        let snapshot = TopNotchSnapshot(projects: feedbackInbox.projects(for: settingsStore.settings.routes))
        model.snapshot = snapshot

        if let expandedProjectID = model.expandedProjectID,
           !snapshot.projects.contains(where: { $0.id == expandedProjectID }) {
            model.expandedProjectID = nil
            model.editingFeedbackID = nil
        } else if let editingFeedbackID = model.editingFeedbackID,
                  !snapshot.projects.contains(where: { project in
                      project.items.contains { $0.stableID == editingFeedbackID }
                  }) {
            model.editingFeedbackID = nil
        }
    }

    private func saveFeedbackNote(_ feedback: FeedbackInboxItem, note: String) {
        do {
            try feedbackInbox.updateNote(for: feedback, note: note)
            refreshSnapshot()
            positionPanel(animated: true)
        } catch {
            presentError(title: "Could Not Save Feedback", message: error.localizedDescription)
        }
    }

    private func deleteFeedback(_ feedback: FeedbackInboxItem) {
        do {
            try feedbackInbox.moveToTrash(feedback)
            if model.editingFeedbackID == feedback.stableID {
                model.editingFeedbackID = nil
            }
            refreshSnapshot()
            positionPanel(animated: true)
        } catch {
            presentError(title: "Could Not Delete Feedback", message: error.localizedDescription)
        }
    }

    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        guard settingsStore.settings.topNotchEnabled else { return }

        let interval = model.isExpanded ? 5.0 : 20.0
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshSnapshot()
        }
        timer.tolerance = interval * 0.25
        refreshTimer = timer
    }

    private func restartScreenFollowTimer() {
        screenFollowTimer?.invalidate()
        guard settingsStore.settings.topNotchEnabled else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
            self?.followMouseScreenIfNeeded()
        }
        timer.tolerance = 0.12
        screenFollowTimer = timer
    }

    private func followMouseScreenIfNeeded() {
        guard panel != nil, !model.isExpanded, !model.showsExpandedContent, !model.showsExpandedChrome else { return }
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let displayID = screen.markupDisplayID
        let displayMode = displayMode(for: screen)
        guard currentScreenID != displayID || model.displayMode != displayMode else {
            return
        }

        positionPanel(animated: false, preferredScreen: screen)
    }

    private func positionPanel(animated: Bool, preferredScreen: NSScreen? = nil) {
        guard let panel else { return }

        let screen = preferredScreen ?? targetScreenForPositioning()
        let displayMode = displayMode(for: screen)
        currentScreenID = screen.markupDisplayID
        model.displayMode = displayMode

        let frame = targetFrame(on: screen, displayMode: displayMode)
        if model.isExpanded {
            expandedHoverFrame = targetFrame(on: screen, displayMode: displayMode, isExpanded: true)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.isExpanded ? TopNotchConstants.expandDuration : TopNotchConstants.collapseDuration
                context.timingFunction = model.isExpanded
                    ? CAMediaTimingFunction(controlPoints: 0.20, 0.84, 0.28, 1.00)
                    : CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.20, 1.00)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreenForPositioning() -> NSScreen {
        if model.isExpanded,
           let currentScreenID,
           let screen = NSScreen.screens.first(where: { $0.markupDisplayID == currentScreenID }) {
            return screen
        }

        return screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
            ?? {
                fatalError("Markup requires at least one screen to show the feedback notch.")
            }()
    }

    private func targetFrame(on screen: NSScreen, displayMode: TopNotchDisplayMode) -> NSRect {
        targetFrame(on: screen, displayMode: displayMode, isExpanded: model.isExpanded)
    }

    private func targetFrame(on screen: NSScreen, displayMode: TopNotchDisplayMode, isExpanded: Bool) -> NSRect {
        let size = targetSize(on: screen, displayMode: displayMode, isExpanded: isExpanded)
        let screenFrame = screen.frame

        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func targetSize(on screen: NSScreen, displayMode: TopNotchDisplayMode) -> NSSize {
        targetSize(on: screen, displayMode: displayMode, isExpanded: model.isExpanded)
    }

    private func targetSize(on screen: NSScreen, displayMode: TopNotchDisplayMode, isExpanded: Bool) -> NSSize {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        if !isExpanded {
            let idleSize = displayMode == .builtInNotch
                ? TopNotchConstants.builtInIdleSize
                : TopNotchConstants.externalIdleSize
            return NSSize(
                width: min(idleSize.width, max(64, screenFrame.width - 32)),
                height: idleSize.height
            )
        }

        let width = min(620, max(280, screenFrame.width - 32))
        let baseHeight: CGFloat = 92
        let contentHeight: CGFloat
        if !model.snapshot.hasConfiguredProjects || !model.snapshot.hasPendingFeedback {
            contentHeight = 86
        } else {
            contentHeight = projectListHeight()
        }

        let height = min(max(164, baseHeight + contentHeight), max(164, visibleFrame.height - 80))
        return NSSize(width: width, height: height)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func displayMode(for screen: NSScreen) -> TopNotchDisplayMode {
        screen.isMarkupBuiltInDisplay ? .builtInNotch : .externalEdge
    }

    private func isMouseInsideStableHoverArea() -> Bool {
        let mouseLocation = NSEvent.mouseLocation

        if let expandedHoverFrame,
           expandedHoverFrame.insetBy(dx: -TopNotchConstants.hoverTolerance, dy: -TopNotchConstants.hoverTolerance).contains(mouseLocation) {
            return true
        }

        if let panel,
           panel.frame.insetBy(dx: -TopNotchConstants.hoverTolerance, dy: -TopNotchConstants.hoverTolerance).contains(mouseLocation) {
            return true
        }

        return false
    }

    private func projectListHeight() -> CGFloat {
        let projects = Array(model.snapshot.sortedProjects.prefix(TopNotchConstants.maximumVisibleProjectRows))
        guard !projects.isEmpty else { return 0 }

        let rowSpacing = TopNotchConstants.projectRowSpacing
        var height = CGFloat(projects.count) * TopNotchConstants.projectRowHeight
            + CGFloat(max(0, projects.count - 1)) * rowSpacing

        if let expandedProjectID = model.expandedProjectID,
           let project = projects.first(where: { $0.id == expandedProjectID }),
           !project.items.isEmpty {
            height += TopNotchConstants.projectFeedbackListTopPadding
            height += CGFloat(project.items.count) * TopNotchConstants.feedbackRowHeight
            height += CGFloat(max(0, project.items.count - 1)) * TopNotchConstants.feedbackRowSpacing
            height += TopNotchConstants.projectFeedbackListBottomPadding

            if let editingFeedbackID = model.editingFeedbackID,
               project.items.contains(where: { $0.stableID == editingFeedbackID }) {
                height += TopNotchConstants.feedbackEditorExtraHeight
            }
        }

        if model.snapshot.projects.count > projects.count {
            height += rowSpacing + TopNotchConstants.hiddenProjectsHeight
        }

        return height
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TopNotchModel: ObservableObject {
    @Published var snapshot = TopNotchSnapshot(projects: [])
    @Published var isExpanded = false
    @Published var showsExpandedContent = false
    @Published var showsExpandedChrome = false
    @Published var expandedProjectID: String? {
        didSet {
            guard oldValue != expandedProjectID else { return }
            if let editingFeedbackID,
               let expandedProjectID,
               let project = snapshot.project(withID: expandedProjectID),
               !project.items.contains(where: { $0.stableID == editingFeedbackID }) {
                self.editingFeedbackID = nil
            }
            layoutInvalidated?()
        }
    }
    @Published var editingFeedbackID: String? {
        didSet {
            guard oldValue != editingFeedbackID else { return }
            layoutInvalidated?()
        }
    }
    @Published var displayMode: TopNotchDisplayMode = .externalEdge

    var onHoverChanged: ((Bool) -> Void)?
    var openScreenshot: ((FeedbackInboxItem) -> Void)?
    var revealFeedback: ((FeedbackInboxItem) -> Void)?
    var saveFeedbackNote: ((FeedbackInboxItem, String) -> Void)?
    var deleteFeedback: ((FeedbackInboxItem) -> Void)?
    var layoutInvalidated: (() -> Void)?
}

private enum TopNotchDisplayMode: Equatable {
    case builtInNotch
    case externalEdge
}

private struct TopNotchSnapshot {
    var projects: [FeedbackInboxProject]

    var sortedProjects: [FeedbackInboxProject] {
        projects.sorted { lhs, rhs in
            let lhsDate = lhs.items.first?.createdAt ?? .distantPast
            let rhsDate = rhs.items.first?.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var totalCount: Int {
        projects.reduce(0) { $0 + $1.items.count }
    }

    var activeProjectCount: Int {
        projects.filter { !$0.items.isEmpty }.count
    }

    var hasConfiguredProjects: Bool {
        !projects.isEmpty
    }

    var hasPendingFeedback: Bool {
        totalCount > 0
    }

    func project(withID id: String) -> FeedbackInboxProject? {
        projects.first { $0.id == id }
    }
}

private enum TopNotchConstants {
    static let builtInIdleSize = NSSize(width: 220, height: 38)
    static let externalIdleSize = NSSize(width: 132, height: 18)
    static let maximumVisibleProjectRows = 6
    static let projectRowHeight: CGFloat = 58
    static let projectRowSpacing: CGFloat = 8
    static let projectFeedbackListTopPadding: CGFloat = 8
    static let projectFeedbackListBottomPadding: CGFloat = 10
    static let feedbackRowHeight: CGFloat = 42
    static let feedbackRowSpacing: CGFloat = 6
    static let feedbackEditorExtraHeight: CGFloat = 84
    static let hiddenProjectsHeight: CGFloat = 20
    static let contentRevealDelay: TimeInterval = 0.08
    static let contentFadeOutDelay: TimeInterval = 0.11
    static let expandDuration: TimeInterval = 0.34
    static let collapseDuration: TimeInterval = 0.24
    static let hoverTolerance: CGFloat = 14
}

private struct TopNotchPanelView: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        ZStack(alignment: .top) {
            backgroundChrome

            if model.isExpanded || model.showsExpandedContent {
                expandedContent
                    .opacity(model.showsExpandedContent ? 1 : 0)
                    .scaleEffect(model.showsExpandedContent ? 1 : 0.985, anchor: .top)
                    .offset(y: model.showsExpandedContent ? 0 : -5)
            }

        }
        .clipShape(TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius))
        .contentShape(Rectangle())
        .onHover { model.onHoverChanged?($0) }
        .animation(.interactiveSpring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.08), value: model.isExpanded)
        .animation(.interactiveSpring(response: 0.38, dampingFraction: 0.88, blendDuration: 0.08), value: model.showsExpandedChrome)
        .animation(.easeInOut(duration: 0.16), value: model.showsExpandedContent)
        .animation(.easeInOut(duration: 0.16), value: model.displayMode)
    }

    @ViewBuilder
    private var backgroundChrome: some View {
        if model.showsExpandedChrome {
            TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                .fill(.regularMaterial)
                .overlay(
                    TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                        .fill(Color.black.opacity(0.72))
                )
                .overlay(
                    TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                        .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.34), radius: 24, y: 7)
        } else if model.displayMode == .externalEdge {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.78)))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 74, height: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .shadow(color: Color.black.opacity(0.28), radius: 6, y: 3)
        } else {
            Color.clear
        }
    }

    private var chromeCornerRadius: CGFloat {
        model.showsExpandedChrome ? 24 : 18
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.snapshot.hasConfiguredProjects {
                TopNotchEmptyState(
                    systemName: "folder.badge.plus",
                    title: "No projects configured",
                    detail: "Add an app route in Settings."
                )
            } else if !model.snapshot.hasPendingFeedback {
                TopNotchEmptyState(
                    systemName: "checkmark.circle",
                    title: "No pending feedback",
                    detail: "Saved feedback will appear here."
                )
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: TopNotchConstants.projectRowSpacing) {
                        ForEach(visibleProjects, id: \.id) { project in
                            TopNotchProjectRow(project: project, model: model)
                        }

                        if hiddenProjectCount > 0 {
                            Text("\(hiddenProjectCount) more \(hiddenProjectCount == 1 ? "project" : "projects") in the menu bar inbox")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.52))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.22))
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Feedback Inbox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(summaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            Spacer(minLength: 12)

            Text(itemCountText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                )
        }
    }

    private var visibleProjects: [FeedbackInboxProject] {
        Array(sortedProjects.prefix(TopNotchConstants.maximumVisibleProjectRows))
    }

    private var hiddenProjectCount: Int {
        max(0, sortedProjects.count - visibleProjects.count)
    }

    private var sortedProjects: [FeedbackInboxProject] {
        model.snapshot.sortedProjects
    }

    private var summaryText: String {
        if !model.snapshot.hasConfiguredProjects {
            return "Routes are configured from Settings"
        }
        if !model.snapshot.hasPendingFeedback {
            return "\(model.snapshot.projects.count) configured \(model.snapshot.projects.count == 1 ? "project" : "projects")"
        }
        return "\(model.snapshot.activeProjectCount) active \(model.snapshot.activeProjectCount == 1 ? "project" : "projects")"
    }

    private var itemCountText: String {
        let count = model.snapshot.totalCount
        return count == 1 ? "1 item" : "\(count) items"
    }

}

private struct TopAttachedRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()

        return path
    }
}

private extension NSScreen {
    var markupDisplayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    var isMarkupBuiltInDisplay: Bool {
        guard let displayID = markupDisplayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}

private struct TopNotchProjectRow: View {
    let project: FeedbackInboxProject
    let model: TopNotchModel

    private var feedback: FeedbackInboxItem? {
        project.items.first
    }

    private var isExpanded: Bool {
        model.expandedProjectID == project.id
    }

    private var isEditingProjectFeedback: Bool {
        guard let editingFeedbackID = model.editingFeedbackID else { return false }
        return project.items.contains { $0.stableID == editingFeedbackID }
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow

            if isExpanded, !project.items.isEmpty {
                VStack(spacing: TopNotchConstants.feedbackRowSpacing) {
                    ForEach(project.items, id: \.stableID) { feedback in
                        TopNotchFeedbackRow(feedback: feedback, model: model)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, TopNotchConstants.projectFeedbackListTopPadding)
                .padding(.bottom, TopNotchConstants.projectFeedbackListBottomPadding)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(feedback == nil ? 0.045 : 0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(isExpanded ? 0.14 : 0.08), lineWidth: 0.5)
        )
        .onHover { isHovering in
            if isHovering {
                model.expandedProjectID = project.id
            } else if !isEditingProjectFeedback {
                model.expandedProjectID = nil
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: feedback == nil ? "folder" : "text.bubble")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(feedback == nil ? Color.white.opacity(0.42) : Color(nsColor: .controlAccentColor))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(project.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(project.items.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }

                Text(feedback?.title ?? "No feedback yet")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(feedback == nil ? Color.white.opacity(0.42) : Color.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let feedback {
                Text(displayDate(for: feedback.createdAt))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: TopNotchConstants.projectRowHeight)
    }

    private func displayDate(for date: Date?) -> String {
        guard let date else { return "" }

        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return formatter.string(from: date)
    }
}

private struct TopNotchFeedbackRow: View {
    let feedback: FeedbackInboxItem
    let model: TopNotchModel

    @State private var draftNote = ""

    private var isEditing: Bool {
        model.editingFeedbackID == feedback.stableID
    }

    private var displayNote: String {
        let note = feedback.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? feedback.title : note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            summaryRow

            if isEditing {
                editor
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            draftNote = feedback.note
        }
        .onChange(of: feedback.stableID) { _ in
            draftNote = feedback.note
        }
        .onChange(of: isEditing) { isEditing in
            if isEditing {
                draftNote = feedback.note
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(nsColor: .controlAccentColor).opacity(0.92))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayNote)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(displayDate(for: feedback.createdAt))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                TopNotchIconButton(systemName: isEditing ? "xmark" : "pencil", help: isEditing ? "Cancel Editing" : "Edit Feedback", isEnabled: true) {
                    if isEditing {
                        draftNote = feedback.note
                        model.editingFeedbackID = nil
                    } else {
                        model.editingFeedbackID = feedback.stableID
                    }
                }

                TopNotchIconButton(systemName: "photo", help: "Open Screenshot", isEnabled: feedback.screenshotURL != nil) {
                    model.openScreenshot?(feedback)
                }

                TopNotchIconButton(systemName: "folder", help: "Reveal in Finder", isEnabled: true) {
                    model.revealFeedback?(feedback)
                }

                TopNotchIconButton(systemName: "trash", help: "Move to Trash", isEnabled: true, tint: .red) {
                    model.deleteFeedback?(feedback)
                }
            }
        }
        .frame(height: TopNotchConstants.feedbackRowHeight)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 7) {
            TextEditor(text: $draftNote)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                Button {
                    draftNote = feedback.note
                    model.editingFeedbackID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.66))
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .help("Cancel")

                Button {
                    model.saveFeedbackNote?(feedback, draftNote)
                    model.editingFeedbackID = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Save")
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Capsule().fill(Color(nsColor: .controlAccentColor).opacity(0.86)))
                .help("Save Feedback")
            }
        }
        .padding(.bottom, 2)
    }

    private func displayDate(for date: Date?) -> String {
        guard let date else { return "Unknown time" }

        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        }
        return formatter.string(from: date)
    }
}

private struct TopNotchIconButton: View {
    let systemName: String
    let help: String
    let isEnabled: Bool
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(buttonTint.opacity(isEnabled ? 0.82 : 0.28))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isEnabled ? 0.09 : 0.04))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }

    private var buttonTint: Color {
        tint ?? .white
    }
}

private struct TopNotchEmptyState: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(0.42))
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.54))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
