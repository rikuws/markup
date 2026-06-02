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
    private var currentScreenID: CGDirectDisplayID?
    private var expandedHoverFrame: NSRect?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore

        model.onHoverChanged = { [weak self] isHovering in
            self?.setHovering(isHovering)
        }
        model.openInstruction = { feedback in
            NSWorkspace.shared.open(feedback.instructionURL)
        }
        model.openScreenshot = { feedback in
            guard let screenshotURL = feedback.screenshotURL else { return }
            NSWorkspace.shared.open(screenshotURL)
        }
        model.revealFeedback = { feedback in
            NSWorkspace.shared.activateFileViewerSelecting([feedback.directoryURL])
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
        refreshTimer?.invalidate()
        screenFollowTimer?.invalidate()
        refreshTimer = nil
        screenFollowTimer = nil
        model.isExpanded = false
        model.showsExpandedContent = false
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
            self.setExpanded(false)
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func setExpanded(_ isExpanded: Bool) {
        contentRevealWorkItem?.cancel()
        frameCollapseWorkItem?.cancel()

        guard model.isExpanded != isExpanded else {
            if isExpanded {
                refreshSnapshot()
                revealExpandedContent(after: 0.02)
            }
            return
        }

        if isExpanded {
            refreshSnapshot()
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
            self.expandedHoverFrame = nil
        }
        frameCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TopNotchConstants.contentFadeOutDelay, execute: workItem)
    }

    private func refreshSnapshot() {
        model.snapshot = TopNotchSnapshot(projects: feedbackInbox.projects(for: settingsStore.settings.routes))
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
        guard panel != nil, !model.isExpanded, !model.showsExpandedContent else { return }
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
            let visibleProjectCount = min(model.snapshot.projects.count, TopNotchConstants.maximumVisibleProjectRows)
            let overflowHeight: CGFloat = model.snapshot.projects.count > visibleProjectCount ? 28 : 0
            contentHeight = CGFloat(visibleProjectCount) * 66 + overflowHeight
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
}

private final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TopNotchModel: ObservableObject {
    @Published var snapshot = TopNotchSnapshot(projects: [])
    @Published var isExpanded = false
    @Published var showsExpandedContent = false
    @Published var displayMode: TopNotchDisplayMode = .externalEdge

    var onHoverChanged: ((Bool) -> Void)?
    var openInstruction: ((FeedbackInboxItem) -> Void)?
    var openScreenshot: ((FeedbackInboxItem) -> Void)?
    var revealFeedback: ((FeedbackInboxItem) -> Void)?
}

private enum TopNotchDisplayMode: Equatable {
    case builtInNotch
    case externalEdge
}

private struct TopNotchSnapshot {
    var projects: [FeedbackInboxProject]

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
}

private enum TopNotchConstants {
    static let builtInIdleSize = NSSize(width: 220, height: 38)
    static let externalIdleSize = NSSize(width: 132, height: 18)
    static let maximumVisibleProjectRows = 6
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
        .animation(.easeInOut(duration: 0.16), value: model.showsExpandedContent)
        .animation(.easeInOut(duration: 0.16), value: model.displayMode)
    }

    @ViewBuilder
    private var backgroundChrome: some View {
        if model.isExpanded {
            TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                .fill(.regularMaterial)
                .overlay(
                    TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                        .fill(Color.black.opacity(model.isExpanded ? 0.72 : 0.74))
                )
                .overlay(
                    TopAttachedRoundedRectangle(cornerRadius: chromeCornerRadius)
                        .stroke(Color.white.opacity(model.isExpanded ? 0.20 : 0.13), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(model.isExpanded ? 0.34 : 0.26), radius: model.isExpanded ? 24 : 12, y: 7)
        } else if model.displayMode == .externalEdge {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.black.opacity(0.78)))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 74, height: 5)
                .padding(.top, 2)
                .shadow(color: Color.black.opacity(0.28), radius: 6, y: 3)
        } else {
            Color.clear
        }
    }

    private var chromeCornerRadius: CGFloat {
        model.isExpanded ? 24 : 18
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
                VStack(spacing: 8) {
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
        model.snapshot.projects.sorted { lhs, rhs in
            let lhsDate = lhs.items.first?.createdAt ?? .distantPast
            let rhsDate = rhs.items.first?.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
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

    var body: some View {
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

            HStack(spacing: 5) {
                TopNotchIconButton(systemName: "doc.text", help: "Open Instruction", isEnabled: feedback != nil) {
                    guard let feedback else { return }
                    model.openInstruction?(feedback)
                }

                TopNotchIconButton(systemName: "photo", help: "Open Screenshot", isEnabled: feedback?.screenshotURL != nil) {
                    guard let feedback else { return }
                    model.openScreenshot?(feedback)
                }

                TopNotchIconButton(systemName: "folder", help: "Reveal in Finder", isEnabled: feedback != nil) {
                    guard let feedback else { return }
                    model.revealFeedback?(feedback)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(feedback == nil ? 0.045 : 0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
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

private struct TopNotchIconButton: View {
    let systemName: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(isEnabled ? 0.82 : 0.28))
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
