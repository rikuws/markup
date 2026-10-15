import Foundation

/// One explicit send creates one issue. A durable attempt marker covers the
/// uncertain interval between the request leaving this Mac and its response.
/// A receipt then makes screenshot retries resume the existing issue.
actor CloudFeedbackClient {
    private let session: URLSession
    private let noRedirects = CloudNoRedirects()
    private var sendingBundles = Set<URL>()
    private static let receiptName = "cloud-delivery.json"
    private static let attemptName = "cloud-delivery-attempt.json"

    init(session: URLSession = .shared) { self.session = session }

    func catalog(for destination: FeedbackDestination, token: String) async throws -> DestinationCatalog {
        try validateToken(token)
        switch destination.provider {
        case .linear:
            let workspace = try await linear("query { organization { name } }", token: token)
            let teams = try await linearOptions(field: "teams", token: token)
            guard !teams.isEmpty else {
                throw CloudDeliveryError(message: "No Linear teams are available to this key. Allow access to a team in Linear, then reconnect.")
            }
            var projects: [DestinationOption] = []
            if !destination.teamID.isEmpty {
                guard teams.contains(where: { $0.id == destination.teamID }) else {
                    throw CloudDeliveryError(message: "This key no longer has access to the selected Linear team. Choose another team.")
                }
                projects = try await linearOptions(field: "projects", teamID: destination.teamID, token: token)
            }
            return DestinationCatalog(workspaceName: (workspace["organization"] as? [String: Any])?["name"] as? String ?? "Linear", teams: teams, projects: projects, issueTypes: [])
        case .jira:
            let site = try destination.validatedSiteURL()
            let projects = try await jiraPages(path: "rest/api/3/project/search", key: "values", destination: destination, token: token, extraQuery: [URLQueryItem(name: "action", value: "create")])
            guard !projects.isEmpty else {
                throw CloudDeliveryError(message: "No Jira projects allow this account to create issues. Ask your Jira administrator for project access, then reconnect.")
            }
            var issueTypes: [[String: Any]] = []
            if !destination.projectID.isEmpty {
                guard projects.contains(where: { $0["id"] as? String == destination.projectID }) else {
                    throw CloudDeliveryError(message: "This account no longer has access to the selected Jira project. Choose another project.")
                }
                issueTypes = try await jiraPages(path: "rest/api/3/issue/createmeta/\(pathID(destination.projectID))/issuetypes", key: "issueTypes", destination: destination, token: token)
                    .filter { $0["subtask"] as? Bool != true }
                guard !issueTypes.isEmpty else {
                    throw CloudDeliveryError(message: "This project has no issue types that Markup can create. Check your Create issues permission in Jira.")
                }
            }
            return DestinationCatalog(workspaceName: site.host ?? "Jira", teams: [], projects: options(projects), issueTypes: options(issueTypes))
        }
    }

    func send(bundleURL: URL, destination: FeedbackDestination, token: String) async throws -> CloudDeliveryReceipt {
        try validateToken(token)
        let bundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard sendingBundles.insert(bundleURL).inserted else {
            throw CloudDeliveryError(message: "This feedback is already being sent.")
        }
        defer { sendingBundles.remove(bundleURL) }
        let receiptURL = bundleURL.appendingPathComponent(Self.receiptName)
        let attemptURL = bundleURL.appendingPathComponent(Self.attemptName)
        let content = try CloudBundle(url: bundleURL)
        var receipt: CloudDeliveryReceipt

        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipt = try JSONDecoder().decode(CloudDeliveryReceipt.self, from: Data(contentsOf: receiptURL))
            try receipt.validate(for: destination)
            if receipt.complete { return receipt }
        } else {
            guard !FileManager.default.fileExists(atPath: attemptURL.path) else {
                throw CloudDeliveryError(message: "A previous send did not receive a confirmed response. Check \(destination.provider.displayName) for this feedback before sending again; Markup has kept the local copy and will not create a duplicate.", canRetry: false)
            }
            try validateDestination(destination)
            if destination.provider == .jira {
                try await validateJiraCreation(destination: destination, token: token, content: content)
            }
            let marker: [String: String] = ["destinationID": destination.id.uuidString, "provider": destination.provider.rawValue, "startedAt": ISO8601DateFormatter().string(from: Date()), "title": content.title]
            // Exclusive creation also protects against another process sending this bundle.
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: attemptURL, options: .withoutOverwriting)
            do {
                receipt = try await createIssue(content: content, destination: destination, token: token)
            } catch {
                // These responses explicitly rejected creation. Timeouts, 5xx, or
                // malformed success responses leave the marker for manual checking.
                if let error = error as? CloudHTTPError, [400, 401, 403, 404, 413, 422, 429].contains(error.status) {
                    try? FileManager.default.removeItem(at: attemptURL)
                    throw error
                }
                throw CloudDeliveryError(message: "\(error.localizedDescription) The issue's creation could not be confirmed. Check \(destination.provider.displayName) before trying again; your feedback is saved locally.", canRetry: false)
            }
            do {
                try persist(receipt, at: receiptURL)
                try? FileManager.default.removeItem(at: attemptURL)
            } catch {
                throw CloudDeliveryError(message: "\(receipt.issueKey) was created, but its receipt could not be saved. Open the issue before trying again.", receipt: receipt, canRetry: false)
            }
        }

        do {
            if destination.provider == .jira {
                // Recover uploads that succeeded before a response was interrupted.
                let remote = try await jira(path: "rest/api/3/issue/\(pathID(receipt.issueID))", destination: destination, token: token, query: [URLQueryItem(name: "fields", value: "attachment")])
                let fields = remote["fields"] as? [String: Any]
                let attachments = fields?["attachment"] as? [[String: Any]] ?? []
                let names = Set(attachments.compactMap { $0["filename"] as? String })
                receipt.attachedFiles = content.images.map(\.name).filter { names.contains($0) }
                try persist(receipt, at: receiptURL)
            }
            for image in content.images where !receipt.attachedFiles.contains(image.name) {
                try Task.checkCancellation()
                if destination.provider == .linear {
                    let assetURL: URL
                    if let existing = receipt.uploadedAssets[image.name] {
                        assetURL = existing
                    } else {
                        assetURL = try await uploadLinear(image, token: token)
                        receipt.uploadedAssets[image.name] = assetURL
                        try persist(receipt, at: receiptURL)
                    }
                    let result = try await linear("mutation($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success } }", variables: ["input": ["issueId": receipt.issueID, "title": image.title, "url": assetURL.absoluteString]], token: token)
                    try requireSuccess(result, field: "attachmentCreate")
                } else {
                    try await uploadJira(image, issueID: receipt.issueID, destination: destination, token: token)
                }
                receipt.attachedFiles.append(image.name)
                try persist(receipt, at: receiptURL)
            }
            receipt.complete = true
            try persist(receipt, at: receiptURL)
            return receipt
        } catch {
            throw CloudDeliveryError(message: "\(receipt.issueKey) was created, but some screenshots still need to be attached. \(error.localizedDescription)", receipt: receipt)
        }
    }

    private func createIssue(content: CloudBundle, destination: FeedbackDestination, token: String) async throws -> CloudDeliveryReceipt {
        switch destination.provider {
        case .linear:
            var input: [String: Any] = ["teamId": destination.teamID, "title": content.title, "description": content.markdown]
            if !destination.projectID.isEmpty { input["projectId"] = destination.projectID }
            // Preserve returned identity even if GraphQL also reports a partial error.
            let result = try await linear("mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }", variables: ["input": input], token: token, allowPartialData: true)
            guard let payload = result["issueCreate"] as? [String: Any],
                  let issue = payload["issue"] as? [String: Any],
                  let id = issue["id"] as? String, !id.isEmpty,
                  let key = issue["identifier"] as? String, !key.isEmpty,
                  let rawURL = issue["url"] as? String, let url = URL(string: rawURL),
                  url.scheme == "https", url.host == "linear.app",
                  url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443
            else { throw CloudDeliveryError(message: "Linear did not return a confirmed issue.") }
            return CloudDeliveryReceipt(destinationID: destination.id, provider: .linear, issueID: id, issueKey: key, issueURL: url)
        case .jira:
            let result = try await jira(path: "rest/api/3/issue", destination: destination, token: token, method: "POST", body: ["fields": ["project": ["id": destination.projectID], "issuetype": ["id": destination.issueTypeID], "summary": content.title, "description": content.atlassianDocument]])
            guard let id = result["id"] as? String, !id.isEmpty, let key = result["key"] as? String, !key.isEmpty else {
                throw CloudDeliveryError(message: "Jira did not return a confirmed issue.")
            }
            let url = try destination.validatedSiteURL().appendingPathComponent("browse").appendingPathComponent(pathID(key))
            return CloudDeliveryReceipt(destinationID: destination.id, provider: .jira, issueID: id, issueKey: key, issueURL: url)
        }
    }

    private func validateJiraCreation(destination: FeedbackDestination, token: String, content: CloudBundle) async throws {
        let fields = try await jiraPages(path: "rest/api/3/issue/createmeta/\(pathID(destination.projectID))/issuetypes/\(pathID(destination.issueTypeID))", key: "fields", destination: destination, token: token)
        let supplied = Set(["project", "issuetype", "summary", "description"])
        let unsupported = fields.filter {
            $0["required"] as? Bool == true && $0["hasDefaultValue"] as? Bool != true && !supplied.contains($0["fieldId"] as? String ?? $0["key"] as? String ?? "")
        }.compactMap { $0["name"] as? String }
        guard unsupported.isEmpty else {
            throw CloudDeliveryError(message: "This Jira issue type requires \(unsupported.joined(separator: ", ")). Choose an issue type with defaults for these fields, or update its configuration in Jira.")
        }
        let settings = try await jira(path: "rest/api/3/attachment/meta", destination: destination, token: token)
        guard settings["enabled"] as? Bool == true else {
            throw CloudDeliveryError(message: "Attachments are disabled on this Jira site. Enable them before sending visual feedback.")
        }
        if let limit = settings["uploadLimit"] as? Int, content.images.contains(where: { $0.data.count > limit }) {
            throw CloudDeliveryError(message: "A screenshot exceeds this Jira site's attachment size limit. Capture a smaller window or area.")
        }
    }

    private func uploadLinear(_ image: CloudBundle.Image, token: String) async throws -> URL {
        let result = try await linear("mutation($name: String!, $size: Int!) { fileUpload(contentType: \"image/png\", filename: $name, size: $size) { success uploadFile { uploadUrl assetUrl headers { key value } } } }", variables: ["name": image.name, "size": image.data.count], token: token)
        try requireSuccess(result, field: "fileUpload")
        guard let payload = result["fileUpload"] as? [String: Any], let file = payload["uploadFile"] as? [String: Any],
              let rawUpload = file["uploadUrl"] as? String, let uploadURL = URL(string: rawUpload), uploadURL.scheme == "https", uploadURL.user == nil, uploadURL.password == nil,
              let rawAsset = file["assetUrl"] as? String, let assetURL = URL(string: rawAsset), assetURL.scheme == "https",
              let headers = file["headers"] as? [[String: String]] else {
            throw CloudDeliveryError(message: "Linear did not return a secure screenshot upload URL.")
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = image.data
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("public, max-age=31536000", forHTTPHeaderField: "Cache-Control")
        for header in headers {
            if let key = header["key"], let value = header["value"] { request.setValue(value, forHTTPHeaderField: key) }
        }
        // The API key is deliberately absent from the presigned storage request.
        _ = try await data(for: request)
        return assetURL
    }

    private func uploadJira(_ image: CloudBundle.Image, issueID: String, destination: FeedbackDestination, token: String) async throws {
        var request = try jiraRequest(path: "rest/api/3/issue/\(pathID(issueID))/attachments", destination: destination, token: token)
        let boundary = "Markup-\(UUID().uuidString)"
        request.httpMethod = "POST"
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(image.name)\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        body.append(image.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        let response = try await data(for: request)
        guard let attachments = try JSONSerialization.jsonObject(with: response) as? [[String: Any]],
              attachments.contains(where: { $0["filename"] as? String == image.name }) else {
            throw CloudDeliveryError(message: "Jira did not confirm the screenshot attachment. Retry to check its upload.")
        }
    }

    private func linearOptions(field: String, teamID: String? = nil, token: String) async throws -> [DestinationOption] {
        var found: [DestinationOption] = []
        var cursor: String?
        repeat {
            var variables: [String: Any] = ["after": cursor as Any? ?? NSNull()]
            let selection = "\(field)(first: 100, after: $after) { nodes { id name } pageInfo { hasNextPage endCursor } }"
            let query: String
            if let teamID {
                variables["team"] = teamID
                query = "query($after: String, $team: String!) { team(id: $team) { \(selection) } }"
            } else { query = "query($after: String) { \(selection) }" }
            let result = try await linear(query, variables: variables, token: token)
            let parent = teamID == nil ? result : (result["team"] as? [String: Any] ?? [:])
            guard let connection = parent[field] as? [String: Any], let nodes = connection["nodes"] as? [[String: Any]], let page = connection["pageInfo"] as? [String: Any] else {
                throw CloudDeliveryError(message: "Linear returned an incomplete destination list. Try connecting again.")
            }
            found.append(contentsOf: options(nodes))
            if page["hasNextPage"] as? Bool != true { break }
            guard let next = page["endCursor"] as? String, !next.isEmpty, next != cursor else {
                throw CloudDeliveryError(message: "Linear could not finish loading destinations. Try connecting again.")
            }
            cursor = next
        } while true
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func jiraPages(path: String, key: String, destination: FeedbackDestination, token: String, extraQuery: [URLQueryItem] = []) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var start = 0
        repeat {
            let page = try await jira(path: path, destination: destination, token: token, query: extraQuery + [URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "100")])
            guard let values = page[key] as? [[String: Any]] else {
                throw CloudDeliveryError(message: "Jira returned an incomplete destination list. Try connecting again.")
            }
            items.append(contentsOf: values)
            start += values.count
            if page["isLast"] as? Bool == true || start >= (page["total"] as? Int ?? start) { break }
            guard !values.isEmpty else {
                throw CloudDeliveryError(message: "Jira could not finish loading destinations. Try connecting again.")
            }
        } while true
        return items
    }

    private func linear(_ query: String, variables: [String: Any] = [:], token: String, allowPartialData: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let result = try object(await data(for: request))
        let errors = result["errors"] as? [[String: Any]] ?? []
        if !errors.isEmpty && !allowPartialData {
            throw CloudDeliveryError(message: "Linear could not complete the request. Check this key's permissions and the selected team or project.")
        }
        guard let payload = result["data"] as? [String: Any] else {
            throw CloudDeliveryError(message: "Linear could not complete the request. Check this key's permissions and try again.")
        }
        return payload
    }

    private func jira(path: String, destination: FeedbackDestination, token: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var request = try jiraRequest(path: path, destination: destination, token: token, query: query)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try object(await data(for: request))
    }

    private func jiraRequest(path: String, destination: FeedbackDestination, token: String, query: [URLQueryItem] = []) throws -> URLRequest {
        let site = try destination.validatedSiteURL()
        let email = destination.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.contains(":"), !email.contains(where: { $0.isWhitespace }) else {
            throw CloudDeliveryError(message: "Enter the email address for your Atlassian account.")
        }
        var parts = URLComponents(url: site.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Data("\(email):\(token)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func data(for input: URLRequest) async throws -> Data {
        var request = input
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        guard let response = response as? HTTPURLResponse else {
            throw CloudDeliveryError(message: "The service did not return an HTTP response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CloudHTTPError(status: response.statusCode)
        }
        return data
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudDeliveryError(message: "The service returned an unreadable response.")
        }
        return object
    }

    private func options(_ values: [[String: Any]]) -> [DestinationOption] {
        values.compactMap { value in
            guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
            return DestinationOption(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func requireSuccess(_ result: [String: Any], field: String) throws {
        guard (result[field] as? [String: Any])?["success"] as? Bool == true else {
            throw CloudDeliveryError(message: "Linear did not confirm the screenshot attachment.")
        }
    }

    private func validateToken(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw CloudDeliveryError(message: "Reconnect this destination with a valid API key or token in Settings.")
        }
    }

    private func validateDestination(_ destination: FeedbackDestination) throws {
        if destination.provider == .linear && destination.teamID.isEmpty {
            throw CloudDeliveryError(message: "Choose a Linear team for this destination in Settings.")
        }
        if destination.provider == .jira {
            _ = try destination.validatedSiteURL()
            guard !destination.projectID.isEmpty, !destination.issueTypeID.isEmpty else {
                throw CloudDeliveryError(message: "Choose a Jira project and issue type for this destination in Settings.")
            }
        }
    }

    private func pathID(_ value: String) throws -> String {
        guard !value.isEmpty, value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw CloudDeliveryError(message: "The saved destination has an invalid identifier. Reconnect it in Settings.")
        }
        return value
    }

    private func persist(_ receipt: CloudDeliveryReceipt, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }
}

/// Block even same-service redirects: no token or screenshot may be replayed
/// to a location different from the endpoint that was explicitly authorized.
private final class CloudNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct CloudHTTPError: LocalizedError {
    var status: Int
    var errorDescription: String? {
        switch status {
        case 401: return "The credential was rejected. Reconnect this destination in Settings."
        case 403: return "This account does not have permission to create issues or attachments in this destination."
        case 404: return "The selected team, project, or issue is no longer accessible."
        case 413: return "The screenshot is larger than this service allows."
        case 429: return "The service is receiving too many requests. Wait a moment, then retry."
        case 300..<400: return "The service redirected the request. Reconnect using its current site address."
        default: return "The service could not complete the request (HTTP \(status))."
        }
    }
}

/// Deliberately reconstruct remote context from an allowlist. In particular,
/// project roots, local paths, original images, and metadata.json stay local.
private struct CloudBundle {
    struct Image {
        var name: String
        var title: String
        var data: Data
    }
    var title: String
    var markdown: String
    var atlassianDocument: [String: Any]
    var images: [Image]

    init(url: URL) throws {
        let metadata = try JSONDecoder().decode(FeedbackMetadata.self, from: Data(contentsOf: url.appendingPathComponent(FeedbackAssetNames.metadata)))
        guard !metadata.captures.isEmpty, metadata.captures.count <= 12 else {
            throw CloudDeliveryError(message: "This feedback bundle has no valid marked areas.")
        }
        var images: [Image] = []
        var paragraphs = ["Visual feedback captured with Markup", "Captured: \(metadata.createdAt)"]
        var markdown = ["Visual feedback captured with Markup", "Captured: \(metadata.createdAt)"]
        var usedNames = Set<String>()
        for item in metadata.captures {
            let name = item.assets.annotatedScreenshot
            guard name.range(of: #"^screenshot(?:-[1-9][0-9]*)?\.png$"#, options: .regularExpression) != nil,
                  usedNames.insert(name).inserted else {
                throw CloudDeliveryError(message: "This feedback bundle has an invalid annotated screenshot.")
            }
            let sourceURL = url.appendingPathComponent(name)
            let properties = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            let imageURL = sourceURL.resolvingSymlinksInPath()
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  imageURL.deletingLastPathComponent().path == url.path else {
                throw CloudDeliveryError(message: "The annotated screenshot is outside this feedback bundle.")
            }
            let size = properties.fileSize ?? 0
            guard size > 0, size <= 25 * 1_024 * 1_024 else {
                throw CloudDeliveryError(message: "A screenshot is empty or larger than 25 MB. Capture a smaller window or area.")
            }
            let data = try Data(contentsOf: imageURL)
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw CloudDeliveryError(message: "An annotated screenshot is not a valid PNG image.")
            }
            let heading = "Area \(item.index) · \(item.app.name)"
            images.append(Image(name: name, title: heading, data: data))
            var context = ["App: \(item.app.name)", "Bundle ID: \(item.app.bundleId)", "Window: \(item.app.windowTitle)"]
            if let hosted = item.hostedApp {
                context.append("Hosted runtime: \(hosted.routeName)")
                if let device = hosted.deviceName { context.append("Device: \(device)") }
                if let guest = hosted.guestBundleId { context.append("Guest bundle ID: \(guest)") }
            }
            if let browser = item.browser {
                context.append("Page: \(browser.title)")
                if let rawURL = browser.url, var pageURL = URLComponents(string: rawURL), ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") {
                    pageURL.user = nil
                    pageURL.password = nil
                    if let safeURL = pageURL.url { context.append("URL: \(safeURL.absoluteString)") }
                }
            }
            if let region = item.capture.region {
                context.append("Marked region: x \(region.x), y \(region.y), width \(region.width), height \(region.height) px (origin: top left)")
            }
            context.append("Screenshot: \(name) · \(item.capture.screenshotSize.width) × \(item.capture.screenshotSize.height) px")
            let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            paragraphs.append(contentsOf: [heading, note.isEmpty ? "No note." : note] + context)
            markdown.append("## \(heading)\n\n\(note.isEmpty ? "No note." : note)\n\n" + context.map { "- \($0)" }.joined(separator: "\n"))
        }
        let firstNote = metadata.captures.compactMap(\.note).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let summary = firstNote?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Visual feedback for \(metadata.app.name)"
        title = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.markdown = markdown.joined(separator: "\n\n")
        self.images = images
        atlassianDocument = ["type": "doc", "version": 1, "content": paragraphs.flatMap { paragraph in
            paragraph.components(separatedBy: .newlines).map { line -> [String: Any] in
                ["type": "paragraph", "content": line.isEmpty ? [] : [["type": "text", "text": line]]]
            }
        }]
    }
}
