import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(settingsStore: SettingsStore) {
        let view = SettingsView(settingsStore: settingsStore)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "punchlist Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var hotKey: HotKeySettings

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        _hotKey = State(initialValue: settingsStore.settings.hotKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("punchlist")
                .font(.title2.weight(.semibold))

            permissionsSection
            hotKeySection
            routesSection

            Spacer()
        }
        .padding(22)
        .onReceive(settingsStore.$settings) { settings in
            hotKey = settings.hotKey
        }
    }

    private var permissionsSection: some View {
        GroupBox("Permissions") {
            HStack {
                Button("Open Screen Recording Settings") {
                    openPrivacyPane("Privacy_ScreenCapture")
                }
                Button("Open Accessibility Settings") {
                    openPrivacyPane("Privacy_Accessibility")
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private var hotKeySection: some View {
        GroupBox("Global Hotkey") {
            HStack(spacing: 12) {
                Toggle("Command", isOn: $hotKey.command)
                Toggle("Shift", isOn: $hotKey.shift)
                Toggle("Option", isOn: $hotKey.option)
                Toggle("Control", isOn: $hotKey.control)
                TextField("Key", text: $hotKey.key)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                Button("Save Hotkey") {
                    settingsStore.updateHotKey(hotKey)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private var routesSection: some View {
        GroupBox("App Routes") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Add Route for Frontmost App") {
                        addRouteForFrontmostApp()
                    }
                    Spacer()
                }

                if settingsStore.settings.routes.isEmpty {
                    Text("No routes yet. The first capture for an app will ask where to save feedback.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(settingsStore.settings.routes) { route in
                            RouteRow(route: route, settingsStore: settingsStore)
                        }
                    }
                    .frame(minHeight: 210)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func addRouteForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        RoutePrompts.configureRoute(
            bundleId: app.bundleIdentifier ?? "unknown.bundle",
            appName: app.localizedName ?? "Unknown App",
            settingsStore: settingsStore
        )
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct RouteRow: View {
    let route: AppRoute
    let settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(route.appName)
                    .font(.headline)
                Text(route.bundleId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(route.projectRoot)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(route.feedbackPath)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Change Project") {
                    RoutePrompts.configureRoute(
                        bundleId: route.bundleId,
                        appName: route.appName,
                        settingsStore: settingsStore,
                        existingPath: route.feedbackPath
                    )
                }
                Button("Open Folder") {
                    try? FileManager.default.createDirectory(
                        at: route.feedbackDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(route.feedbackDirectoryURL)
                }
                Button("Remove") {
                    settingsStore.removeRoute(bundleId: route.bundleId)
                }
                Spacer()
            }
        }
        .padding(.vertical, 6)
    }
}

enum RoutePrompts {
    static func configureRoute(
        bundleId: String,
        appName: String,
        settingsStore: SettingsStore,
        existingPath: String = ".punchlist/feedback"
    ) {
        let panel = NSOpenPanel()
        panel.message = "Choose the project folder for \(appName)"
        panel.prompt = "Use This Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let projectRoot = panel.url else {
            return
        }

        let feedbackPath = promptFeedbackPath(appName: appName, existingPath: existingPath)
        settingsStore.upsertRoute(
            bundleId: bundleId,
            appName: appName,
            projectRoot: projectRoot,
            feedbackPath: feedbackPath
        )
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
            : ".punchlist/feedback"
    }
}
