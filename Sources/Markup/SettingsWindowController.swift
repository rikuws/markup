import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(settingsStore: SettingsStore, appUpdater: AppUpdater) {
        let view = SettingsView(settingsStore: settingsStore, appUpdater: appUpdater)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Markup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 780, height: 650))
        window.contentMinSize = NSSize(width: 680, height: 500)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var appUpdater: AppUpdater
    @State private var hotKey: HotKeySettings

    init(settingsStore: SettingsStore, appUpdater: AppUpdater) {
        self.settingsStore = settingsStore
        self.appUpdater = appUpdater
        _hotKey = State(initialValue: settingsStore.settings.hotKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionsSection
                    updatesSection
                    hotKeySection
                    routesSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(settingsStore.$settings) { settings in
            hotKey = settings.hotKey
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Markup")
                    .font(.system(size: 13, weight: .semibold))
                Text("Capture settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(hotKey.normalized.displayString, systemImage: "keyboard")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.thinMaterial))
                .overlay {
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                }
        }
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .frame(height: 52)
        .background(.regularMaterial)
    }

    private var permissionsSection: some View {
        SettingsSection(
            title: "Permissions",
            subtitle: "Markup needs screen capture access before the overlay can open."
        ) {
            HStack(spacing: 10) {
                Button {
                    openPrivacyPane("Privacy_ScreenCapture")
                } label: {
                    Label("Screen Recording", systemImage: "record.circle")
                }

                Button {
                    openPrivacyPane("Privacy_Accessibility")
                } label: {
                    Label("Accessibility", systemImage: "accessibility")
                }

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var hotKeySection: some View {
        SettingsSection(
            title: "Global Hotkey",
            subtitle: "Shown in the menu bar menu and used from any app."
        ) {
            HStack(alignment: .center, spacing: 14) {
                HotKeyToggle(title: "Command", symbol: "\u{2318}", isOn: $hotKey.command)
                HotKeyToggle(title: "Shift", symbol: "\u{21E7}", isOn: $hotKey.shift)
                HotKeyToggle(title: "Option", symbol: "\u{2325}", isOn: $hotKey.option)
                HotKeyToggle(title: "Control", symbol: "\u{2303}", isOn: $hotKey.control)

                TextField("Key", text: $hotKey.key)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .onSubmit(saveHotKey)

                Button {
                    saveHotKey()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hotKeyChanged)

                Spacer()
            }
        }
    }

    private var updatesSection: some View {
        SettingsSection(
            title: "Updates",
            subtitle: "Signed releases are checked from the Markup GitHub feed."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { appUpdater.automaticallyChecksForUpdates },
                    set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                )) {
                    Label("Notify me about updates automatically", systemImage: "bell.badge")
                }

                HStack(spacing: 10) {
                    Button {
                        appUpdater.checkForUpdates(nil)
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!appUpdater.canCheckForUpdates)

                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var routesSection: some View {
        SettingsSection(
            title: "App Routes",
            subtitle: "Apps route by app identity. Browser captures route by the current page or project."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if sortedRoutes.isEmpty {
                    EmptyRoutesView {
                        addRouteForFrontmostApp()
                    }
                } else {
                    HStack {
                        Button {
                            addRouteForFrontmostApp()
                        } label: {
                            Label("Add Frontmost App", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    VStack(spacing: 0) {
                        ForEach(sortedRoutes) { route in
                            RouteRow(route: route, settingsStore: settingsStore)

                            if route.id != sortedRoutes.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var sortedRoutes: [AppRoute] {
        settingsStore.settings.routes.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private var hotKeyChanged: Bool {
        hotKey.normalized != settingsStore.settings.hotKey.normalized
    }

    private func saveHotKey() {
        settingsStore.updateHotKey(hotKey)
    }

    private func addRouteForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let target = RouteTargetResolver.target(for: app)
        RoutePrompts.configureRoute(
            bundleId: target.key,
            appName: target.name,
            settingsStore: settingsStore
        )
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.40), lineWidth: 0.5)
        }
    }
}

struct HotKeyToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 5) {
                Text(symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                Text(title)
            }
        }
        .toggleStyle(.checkbox)
    }
}

struct EmptyRoutesView: View {
    let addRoute: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("No routes configured")
                    .font(.system(size: 13, weight: .semibold))
                Text("The first capture for an app can also ask where to save feedback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                addRoute()
            } label: {
                Label("Add Frontmost App", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }
}

struct RouteRow: View {
    let route: AppRoute
    let settingsStore: SettingsStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(route.appName)
                    .font(.system(size: 13, weight: .semibold))
                Text(route.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(route.projectRoot)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(route.feedbackPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button {
                    RoutePrompts.configureRoute(
                        bundleId: route.bundleId,
                        appName: route.appName,
                        settingsStore: settingsStore,
                        existingRoute: route
                    )
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Change Project")

                Button {
                    try? FileManager.default.createDirectory(
                        at: route.feedbackDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(route.feedbackDirectoryURL)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open Folder")

                Button(role: .destructive) {
                    settingsStore.removeRoute(bundleId: route.bundleId)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove Route")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 11)
    }
}

enum RoutePrompts {
    @discardableResult
    static func configureRoute(
        bundleId: String,
        appName: String,
        settingsStore: SettingsStore,
        existingRoute: AppRoute? = nil,
        existingPath: String = ".markup/feedback",
        asksFeedbackPath: Bool = true
    ) -> AppRoute? {
        let panel = NSOpenPanel()
        panel.message = "Choose the project folder for \(appName)"
        panel.prompt = "Use This Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = existingRoute?.projectRootURL

        guard panel.runModal() == .OK, let projectRoot = panel.url else {
            return nil
        }

        let currentFeedbackPath = existingRoute?.feedbackPath ?? existingPath
        let feedbackPath = asksFeedbackPath
            ? promptFeedbackPath(appName: appName, existingPath: currentFeedbackPath)
            : currentFeedbackPath.trimmedFeedbackPath
        settingsStore.upsertRoute(
            bundleId: bundleId,
            appName: appName,
            projectRoot: projectRoot,
            feedbackPath: feedbackPath
        )

        return settingsStore.route(for: bundleId)
    }

    private static func promptFeedbackPath(appName: String, existingPath: String) -> String {
        let alert = NSAlert()
        alert.messageText = "Feedback Folder"
        alert.informativeText = "Relative folder inside this project for \(appName)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Use Default")

        let field = NSTextField(string: existingPath)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field

        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmedFeedbackPath
            : ".markup/feedback"
    }
}
