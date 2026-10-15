import AppKit
import SwiftUI

struct DestinationSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var editor: DestinationEditorContext?
    @State private var destinationToRemove: FeedbackDestination?
    @State private var removalError: String?

    var body: some View {
        SettingsSection(
            title: "Destinations",
            subtitle: "Save feedback locally, then choose when to send it to Linear or Jira."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if settingsStore.settings.destinations.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 25))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Give feedback a place to go")
                                .font(.body.weight(.medium))
                            Text("Connect a team or project. Your local workflow stays the same.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)
                        addDestinationMenu
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(settingsStore.settings.destinations) { destination in
                            destinationRow(destination)
                            if destination.id != settingsStore.settings.destinations.last?.id {
                                Divider()
                            }
                        }
                    }

                    HStack {
                        addDestinationMenu
                        Spacer()
                        Label("Credentials stay in Keychain", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(item: $editor) { context in
            DestinationEditorView(
                destination: context.destination,
                isNew: context.isNew,
                settingsStore: settingsStore
            )
        }
        .alert("Disconnect destination?", isPresented: Binding(
            get: { destinationToRemove != nil },
            set: { if !$0 { destinationToRemove = nil } }
        ), presenting: destinationToRemove) { destination in
            Button("Cancel", role: .cancel) { destinationToRemove = nil }
            Button("Disconnect", role: .destructive) { removeDestination(destination) }
        } message: { destination in
            Text("“\(destination.name)” and its saved credential will be removed from this Mac. Existing issues and local feedback are kept. To revoke the credential everywhere, use \(destination.provider.displayName)’s token settings.")
        }
        .alert("Couldn’t disconnect", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "The credential could not be removed from Keychain.")
        }
    }

    private var addDestinationMenu: some View {
        Menu {
            ForEach(DestinationProvider.allCases, id: \.self) { provider in
                Button {
                    editor = DestinationEditorContext(
                        destination: FeedbackDestination(provider: provider, name: ""),
                        isNew: true
                    )
                } label: {
                    Label(provider.displayName, systemImage: provider.systemImage)
                }
            }
        } label: {
            Label("Add Destination", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func destinationRow(_ destination: FeedbackDestination) -> some View {
        HStack(spacing: 12) {
            Image(systemName: destination.provider.systemImage)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text([destination.provider.displayName, destination.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button("Edit…") {
                editor = DestinationEditorContext(destination: destination, isNew: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Menu {
                Link("Manage \(destination.provider.displayName) Credentials…", destination: destination.provider.credentialManagementURL)
                Divider()
                Button("Disconnect…", role: .destructive) {
                    destinationToRemove = destination
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Destination options")
            .accessibilityLabel("Options for \(destination.name)")
        }
        .padding(.vertical, 11)
    }

    private func removeDestination(_ destination: FeedbackDestination) {
        do {
            try DestinationCredentials().remove(for: destination.id)
            settingsStore.removeDestination(id: destination.id)
        } catch {
            removalError = "The saved credential could not be removed from Keychain. The destination has been kept so you can try again."
        }
        destinationToRemove = nil
    }
}

private struct DestinationEditorContext: Identifiable {
    let id = UUID()
    let destination: FeedbackDestination
    let isNew: Bool
}

private struct DestinationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settingsStore: SettingsStore
    @State private var destination: FeedbackDestination
    @State private var token = ""
    @State private var catalog: DestinationCatalog?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lookupTask: Task<Void, Never>?
    private let isNew: Bool

    init(destination: FeedbackDestination, isNew: Bool, settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.isNew = isNew
        _destination = State(initialValue: destination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionFields
                    if let catalog {
                        destinationFields(catalog)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(24)
            }

            Divider()

            HStack(spacing: 8) {
                Label("Stored in Keychain on this Mac", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Destination" : "Save Changes", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 550, height: editorHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            lookupTask?.cancel()
            token = ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: destination.provider.systemImage)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(isNew ? "Connect \(destination.provider.displayName)" : "Edit \(destination.provider.displayName) Destination")
                    .font(.title3.weight(.semibold))
                Text("Choose where to send feedback. Feedback stays on this Mac until you choose Send.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if destination.provider == .jira {
                field("Jira Cloud site") {
                    TextField("https://your-team.atlassian.net", text: $destination.siteURL)
                        .onChange(of: destination.siteURL) { invalidateCatalog() }
                }
                field("Account email") {
                    TextField("you@company.com", text: $destination.email)
                        .onChange(of: destination.email) { invalidateCatalog() }
                }
            }

            field(destination.provider == .linear ? "Personal API key" : "API token") {
                SecureField(isNew ? "Paste your credential" : "Use saved credential", text: $token)
                    .onChange(of: token) { invalidateCatalog() }
            }

            if !isNew {
                Text("Leave this blank to use the credential in Keychain, or enter a new one to replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline) {
                Link(destination.provider == .linear ? "Create or manage API keys ↗" : "Create or manage API tokens ↗", destination: destination.provider.credentialManagementURL)
                    .font(.caption)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking connection…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(catalog == nil ? "Verify Connection" : "Refresh") {
                        loadCatalog()
                    }
                    .disabled(!canVerify)
                }
            }

            if destination.provider == .jira {
                Text("Use a Jira Cloud API token without scopes, with permission to create issues and add attachments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func destinationFields(_ catalog: DestinationCatalog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Label(catalog.workspaceName.isEmpty ? "Connection verified" : "Connected to \(catalog.workspaceName)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            field("Destination name") {
                TextField("A name you’ll recognize when sending", text: $destination.name)
                    .textFieldStyle(.roundedBorder)
            }

            if destination.provider == .linear {
                field("Team") {
                    Picker("Team", selection: Binding(
                        get: { destination.teamID },
                        set: { teamID in
                            destination.teamID = teamID
                            destination.projectID = ""
                            self.catalog?.projects = []
                            loadCatalog()
                        }
                    )) {
                        Text("Choose a team").tag("")
                        ForEach(catalog.teams) { team in
                            Text(team.name).tag(team.id)
                        }
                    }
                    .labelsHidden()
                }
                if !destination.teamID.isEmpty {
                    field("Project") {
                        Picker("Project", selection: $destination.projectID) {
                            Text("No project").tag("")
                            ForEach(catalog.projects) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
            } else {
                field("Project") {
                    Picker("Project", selection: Binding(
                        get: { destination.projectID },
                        set: { projectID in
                            destination.projectID = projectID
                            destination.issueTypeID = ""
                            self.catalog?.issueTypes = []
                            loadCatalog()
                        }
                    )) {
                        Text("Choose a project").tag("")
                        ForEach(catalog.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .labelsHidden()
                }
                if !destination.projectID.isEmpty {
                    field("Issue type") {
                        Picker("Issue type", selection: $destination.issueTypeID) {
                            Text("Choose an issue type").tag("")
                            ForEach(catalog.issueTypes) { issueType in
                                Text(issueType.name).tag(issueType.id)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            if destination.provider == .linear && catalog.teams.isEmpty {
                Text("No teams are available to this API key. Check its access in Linear and verify again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if destination.provider == .jira && catalog.projects.isEmpty {
                Text("No projects are available to this account. Check its access in Jira and verify again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if destination.provider == .jira && !destination.projectID.isEmpty && catalog.issueTypes.isEmpty && !isLoading {
                Text("No issue types are available for this project. Choose another project or check your Jira permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isLoading)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.medium))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var canVerify: Bool {
        guard !isLoading, !isNew || !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if destination.provider == .jira {
            return !destination.siteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !destination.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var editorHeight: CGFloat {
        if catalog != nil { return 650 }
        return destination.provider == .linear ? 380 : 520
    }

    private var canSave: Bool {
        guard let catalog, !isLoading, errorMessage == nil,
              !destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch destination.provider {
        case .linear:
            return catalog.teams.contains { $0.id == destination.teamID }
                && (destination.projectID.isEmpty || catalog.projects.contains { $0.id == destination.projectID })
        case .jira:
            return catalog.projects.contains { $0.id == destination.projectID }
                && catalog.issueTypes.contains { $0.id == destination.issueTypeID }
        }
    }

    private func invalidateCatalog() {
        lookupTask?.cancel()
        lookupTask = nil
        isLoading = false
        catalog = nil
        destination.teamID = ""
        destination.projectID = ""
        destination.issueTypeID = ""
        errorMessage = nil
    }

    private func loadCatalog() {
        lookupTask?.cancel()
        isLoading = true
        errorMessage = nil
        let initialDestination = destination
        let needsInitialCatalog = catalog == nil
        let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lookupTask = Task { @MainActor in
            var requestedDestination = initialDestination
            do {
                let credential = enteredToken.isEmpty
                    ? try DestinationCredentials().token(for: requestedDestination.id)
                    : enteredToken
                let client = CloudFeedbackClient()
                if needsInitialCatalog {
                    var unscopedDestination = requestedDestination
                    unscopedDestination.teamID = ""
                    unscopedDestination.projectID = ""
                    unscopedDestination.issueTypeID = ""
                    let initialCatalog = try await client.catalog(for: unscopedDestination, token: credential)
                    guard !Task.isCancelled else { return }
                    catalog = initialCatalog

                    // A revoked team/project should still leave a way to choose
                    // one that the account can access now.
                    if destination.provider == .linear && !initialCatalog.teams.contains(where: { $0.id == destination.teamID }) {
                        destination.teamID = ""
                        destination.projectID = ""
                    } else if destination.provider == .jira && !initialCatalog.projects.contains(where: { $0.id == destination.projectID }) {
                        destination.projectID = ""
                        destination.issueTypeID = ""
                    }
                    requestedDestination = destination
                }
                let hasScope = requestedDestination.provider == .linear
                    ? !requestedDestination.teamID.isEmpty
                    : !requestedDestination.projectID.isEmpty
                let result: DestinationCatalog
                if needsInitialCatalog && !hasScope, let initialCatalog = catalog {
                    result = initialCatalog
                } else {
                    result = try await client.catalog(for: requestedDestination, token: credential)
                }
                guard !Task.isCancelled else { return }
                catalog = result
                if destination.provider == .linear && !result.projects.contains(where: { $0.id == destination.projectID }) {
                    destination.projectID = ""
                } else if destination.provider == .jira && !result.issueTypes.contains(where: { $0.id == destination.issueTypeID }) {
                    destination.issueTypeID = ""
                }
                if destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    destination.name = result.workspaceName.isEmpty ? destination.provider.displayName : result.workspaceName
                }
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func save() {
        guard canSave, let catalog else { return }
        do {
            let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !enteredToken.isEmpty {
                try DestinationCredentials().save(enteredToken, for: destination.id)
            }
            var savedDestination = destination
            savedDestination.name = destination.name.trimmingCharacters(in: .whitespacesAndNewlines)
            savedDestination.siteURL = destination.siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            savedDestination.email = destination.email.trimmingCharacters(in: .whitespacesAndNewlines)
            savedDestination.workspaceName = catalog.workspaceName
            savedDestination.teamName = catalog.teams.first { $0.id == destination.teamID }?.name
            savedDestination.projectName = catalog.projects.first { $0.id == destination.projectID }?.name
            savedDestination.issueTypeName = catalog.issueTypes.first { $0.id == destination.issueTypeID }?.name
            settingsStore.upsertDestination(savedDestination)
            dismiss()
        } catch {
            errorMessage = "The credential couldn’t be saved to Keychain. Your destination has not been changed. Try again."
        }
    }
}

private extension DestinationProvider {
    var credentialManagementURL: URL {
        switch self {
        case .linear:
            URL(string: "https://linear.app/settings/account/security")!
        case .jira:
            URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
        }
    }
}
