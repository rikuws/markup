import AppKit
import SwiftUI

enum DestinationPickerChoice {
    case local
    case cloud(FeedbackDestination)
}

/// A deliberate handoff after capture. Selecting a row never starts an upload.
@MainActor
final class DestinationPickerController: NSWindowController, NSWindowDelegate {
    private let pickerState: DestinationPickerState
    private var choice: DestinationPickerChoice?
    private var isRunning = false

    init(
        routeName: String,
        destinations: [FeedbackDestination],
        suggestedDestinationID: UUID?,
        areaCount: Int
    ) {
        pickerState = DestinationPickerState(
            destinations: destinations,
            suggestedDestinationID: suggestedDestinationID
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Save feedback"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: DestinationPickerView(
            state: pickerState,
            routeName: routeName,
            areaCount: areaCount,
            confirm: { [weak self] in self?.confirmSelection() },
            cancel: { [weak self] in self?.finish(nil) }
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func runModal() -> DestinationPickerChoice? {
        guard let window, !isRunning else { return nil }
        choice = nil
        isRunning = true
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
        defer {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            isRunning = false
            window.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return choice
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func confirmSelection() {
        if let destination = pickerState.selectedDestination {
            finish(.cloud(destination))
        } else {
            finish(.local)
        }
    }

    private func finish(_ choice: DestinationPickerChoice?) {
        guard isRunning else { return }
        self.choice = choice
        NSApp.stopModal(withCode: choice == nil ? .cancel : .OK)
        window?.orderOut(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
            pickerState.searchFocusRequest += 1
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            finish(nil)
            return true
        }
        guard modifiers.isEmpty else { return false }
        // Leave composition keys with the input method until its text is committed.
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        switch event.keyCode {
        case 125:
            pickerState.moveSelection(by: 1)
        case 126:
            pickerState.moveSelection(by: -1)
        case 36, 76:
            confirmSelection()
        case 53:
            finish(nil)
        default:
            return false
        }
        return true
    }
}

@MainActor
private final class DestinationPickerState: ObservableObject {
    let destinations: [FeedbackDestination]
    let suggestedDestinationID: UUID?
    @Published var query = "" {
        didSet {
            if let selectedDestinationID,
               !filteredDestinations.contains(where: { $0.id == selectedDestinationID }) {
                self.selectedDestinationID = nil
            }
        }
    }
    @Published var selectedDestinationID: UUID?
    @Published var searchFocusRequest = 0

    init(destinations: [FeedbackDestination], suggestedDestinationID: UUID?) {
        self.destinations = destinations
        self.suggestedDestinationID = suggestedDestinationID
        selectedDestinationID = destinations.first(where: { $0.id == suggestedDestinationID })?.id
    }

    var filteredDestinations: [FeedbackDestination] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return destinations }
        return destinations.filter { destination in
            let searchable = [
                destination.name, destination.provider.displayName, destination.detail,
                destination.siteURL, destination.teamID, destination.projectID
            ].joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    var selectedDestination: FeedbackDestination? {
        destinations.first(where: { $0.id == selectedDestinationID })
    }

    func moveSelection(by step: Int) {
        let choices: [UUID?] = [nil] + filteredDestinations.map { Optional($0.id) }
        let current = choices.firstIndex(of: selectedDestinationID) ?? 0
        let next = min(max(current + step, 0), choices.count - 1)
        selectedDestinationID = choices[next]
    }
}

private struct DestinationPickerView: View {
    @ObservedObject var state: DestinationPickerState
    let routeName: String
    let areaCount: Int
    let confirm: () -> Void
    let cancel: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 16) {
                captureSummary
                searchField
                destinationList
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            footer
        }
        .frame(width: 520, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { searchFocused = true }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private var titleBar: some View {
        HStack {
            Text("Save feedback")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .frame(height: 48)
        .background(.bar)
    }

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose a destination")
                .font(.system(size: 20, weight: .semibold))
            Text("\(areaCount) annotated \(areaCount == 1 ? "area" : "areas") · \(routeName)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(routeName)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search destinations…", text: $state.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search destinations")
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            } else {
                Text("⌘K")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: searchFocused ? 1.5 : 0.5)
        }
    }

    private var destinationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 3) {
                    destinationRow(
                        title: "Save Locally",
                        subtitle: "Project feedback inbox",
                        symbol: "folder",
                        selected: state.selectedDestinationID == nil,
                        recent: false
                    ) { state.selectedDestinationID = nil }
                    .id("local")

                    if !state.filteredDestinations.isEmpty {
                        HStack {
                            Text("CONNECTED DESTINATIONS")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 13)
                        .padding(.bottom, 4)

                        ForEach(state.filteredDestinations) { destination in
                            destinationRow(
                                title: destination.name,
                                subtitle: destinationSubtitle(destination),
                                symbol: destination.provider.systemImage,
                                selected: state.selectedDestinationID == destination.id,
                                recent: destination.id == state.suggestedDestinationID
                            ) { state.selectedDestinationID = destination.id }
                            .id(destination.id.uuidString)
                        }
                    } else {
                        Text(state.query.isEmpty
                             ? "Connect Linear or Jira in Settings to send feedback to your team."
                             : "No connected destinations match your search.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 24)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.visible)
            .onChange(of: state.selectedDestinationID) { _, newValue in
                proxy.scrollTo(newValue?.uuidString ?? "local")
            }
        }
    }

    private func destinationRow(
        title: String,
        subtitle: String,
        symbol: String,
        selected: Bool,
        recent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if recent {
                    Text("Recent")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(title) — \(subtitle)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("A copy is always kept in your project.", systemImage: "internaldrive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                Text(state.selectedDestination.map { "Send captures and notes to \($0.provider.displayName)." }
                     ?? "Keep captures and notes on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var actionTitle: String {
        state.selectedDestination.map { "Send to \($0.provider.displayName)" } ?? "Save Locally"
    }

    private func destinationSubtitle(_ destination: FeedbackDestination) -> String {
        let detail = destination.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? destination.provider.displayName : "\(destination.provider.displayName) · \(detail)"
    }
}
