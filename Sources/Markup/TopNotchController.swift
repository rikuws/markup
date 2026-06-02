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
    private var collapseWorkItem: DispatchWorkItem?

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
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let contentView = NSHostingView(rootView: TopNotchPanelView(model: model))
        contentView.frame = NSRect(origin: .zero, size: Self.idleSize)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = TopNotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false

        self.panel = panel
    }

    private func closePanel() {
        collapseWorkItem?.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        model.isExpanded = false
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
            if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
                return
            }
            self.setExpanded(false)
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func setExpanded(_ isExpanded: Bool) {
        guard model.isExpanded != isExpanded else {
            if isExpanded {
                refreshSnapshot()
            }
            return
        }

        if isExpanded {
            refreshSnapshot()
        }

        model.isExpanded = isExpanded
        positionPanel(animated: true)
        restartRefreshTimer()
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

    private func positionPanel(animated: Bool) {
        guard let panel else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = targetSize(in: visibleFrame)
        let frame = NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 5,
            width: size.width,
            height: size.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.isExpanded ? 0.24 : 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetSize(in visibleFrame: NSRect) -> NSSize {
        if !model.isExpanded {
            return NSSize(width: min(Self.idleSize.width, max(96, visibleFrame.width - 32)), height: Self.idleSize.height)
        }

        let width = min(620, max(280, visibleFrame.width - 32))
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

    private static let idleSize = NSSize(width: 148, height: 34)
}

private final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TopNotchModel: ObservableObject {
    @Published var snapshot = TopNotchSnapshot(projects: [])
    @Published var isExpanded = false

    var onHoverChanged: ((Bool) -> Void)?
    var openInstruction: ((FeedbackInboxItem) -> Void)?
    var openScreenshot: ((FeedbackInboxItem) -> Void)?
    var revealFeedback: ((FeedbackInboxItem) -> Void)?
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
    static let maximumVisibleProjectRows = 6
}

private struct TopNotchPanelView: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 17, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 17, style: .continuous)
                        .fill(Color.black.opacity(model.isExpanded ? 0.72 : 0.66))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 17, style: .continuous)
                        .stroke(Color.white.opacity(model.isExpanded ? 0.20 : 0.14), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(model.isExpanded ? 0.34 : 0.22), radius: model.isExpanded ? 24 : 14, y: 8)

            if model.isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                idleContent
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: model.isExpanded ? 24 : 17, style: .continuous))
        .contentShape(Rectangle())
        .onHover { model.onHoverChanged?($0) }
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: model.isExpanded)
    }

    private var idleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(0.86))

            Text(compactCount(model.snapshot.totalCount))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            Circle()
                .fill(model.snapshot.hasPendingFeedback ? Color(nsColor: .controlAccentColor) : Color.white.opacity(0.28))
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 14)
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

    private func compactCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
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
