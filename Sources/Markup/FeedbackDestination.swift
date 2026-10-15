import Foundation

enum DestinationProvider: String, Codable, CaseIterable, Sendable {
    case linear
    case jira

    var displayName: String { self == .linear ? "Linear" : "Jira" }
    var systemImage: String { self == .linear ? "line.3.horizontal.decrease.circle" : "square.stack.3d.up" }
}

/// Routing preferences only. Credentials are kept separately in Keychain.
struct FeedbackDestination: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var provider: DestinationProvider
    var name: String
    var siteURL = ""
    var email = ""
    var teamID = ""
    var projectID = ""
    var issueTypeID = ""
    var workspaceName: String?
    var teamName: String?
    var projectName: String?
    var issueTypeName: String?

    var detail: String {
        let names = [workspaceName, teamName, projectName, issueTypeName].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        if !names.isEmpty { return names.joined(separator: " · ") }
        return provider == .jira ? URL(string: siteURL)?.host ?? "" : ""
    }

    func hasSameRouting(as other: FeedbackDestination) -> Bool {
        id == other.id && provider == other.provider && siteURL == other.siteURL
            && email == other.email && teamID == other.teamID
            && projectID == other.projectID && issueTypeID == other.issueTypeID
    }

    /// Credentials must never be sent to arbitrary URLs entered into Settings.
    func validatedSiteURL() throws -> URL {
        let value = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              host.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.atlassian\.net$"#, options: .regularExpression) != nil,
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil,
              let url = URL(string: "https://\(host)")
        else {
            throw CloudDeliveryError(message: "Enter your Jira Cloud site as https://your-team.atlassian.net, without a page path.")
        }
        return url
    }
}

struct DestinationOption: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
}

struct DestinationCatalog: Sendable {
    var workspaceName: String
    var teams: [DestinationOption]
    var projects: [DestinationOption]
    var issueTypes: [DestinationOption]
}

struct CloudDeliveryReceipt: Codable, Sendable {
    var destinationID: UUID
    var provider: DestinationProvider
    var issueID: String
    var issueKey: String
    var issueURL: URL
    var createdAt = Date()
    var uploadedAssets: [String: URL] = [:]
    var attachedFiles: [String] = []
    var complete = false

    /// Validate before a resumed send or displaying the saved link. Presets
    /// retain their UUID when edited, while Jira issue IDs are site-specific.
    func validate(for destination: FeedbackDestination) throws {
        guard destinationID == destination.id, provider == destination.provider else {
            throw CloudDeliveryError(message: "This feedback already belongs to another destination.", canRetry: false)
        }
        guard issueURL.scheme?.lowercased() == "https",
              issueURL.user == nil, issueURL.password == nil,
              issueURL.port == nil || issueURL.port == 443 else {
            throw CloudDeliveryError(message: "This feedback has an invalid saved issue link. Check the issue in \(destination.provider.displayName) before resuming.", canRetry: false)
        }
        let expectedHost: String
        switch destination.provider {
        case .linear:
            expectedHost = "linear.app"
        case .jira:
            expectedHost = try destination.validatedSiteURL().host!
        }
        guard issueURL.host?.lowercased() == expectedHost.lowercased() else {
            // Invalid receipts are deliberately absent from these errors so
            // callers cannot accidentally display an untrusted issue link.
            throw CloudDeliveryError(message: "This feedback belongs to a different \(destination.provider.displayName) site. Restore its original destination before resuming screenshots.", canRetry: false)
        }
    }
}

struct CloudDeliveryError: LocalizedError {
    var message: String
    var receipt: CloudDeliveryReceipt? = nil
    var canRetry = true
    var errorDescription: String? { message }
}
