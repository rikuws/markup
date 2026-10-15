import Foundation
import XCTest
@testable import Markup

final class CloudFeedbackClientTests: XCTestCase {
    private var directory: URL!
    private var network: CloudMockNetwork!
    private var session: URLSession!
    private let token = "fixture-secret-never-upload"
    private let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data("ANNOTATED-FIXTURE".utf8)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MarkupCloudTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        network = CloudMockNetwork()
        session = network.makeSession()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        network.unregister()
        try FileManager.default.removeItem(at: directory)
    }

    func testLinearSendIncludesUsefulContextAndUploadsOnlyAnnotatedImageWithoutAPIKey() async throws {
        try makeBundle(browserURL: "https://private-username:private-password@example.com/design")
        network.enqueue(linearSuccess())

        let receipt = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: linearDestination(), token: token)

        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.issueKey, "DES-42")
        XCTAssertEqual(receipt.attachedFiles, ["screenshot.png"])
        let requests = network.requests
        XCTAssertEqual(requests.count, 4)
        let input = try graphInput(requests[0])
        XCTAssertEqual(input["teamId"] as? String, "team-design")
        XCTAssertEqual(input["projectId"] as? String, "project-mac")
        XCTAssertEqual(input["title"] as? String, "Make the primary action easier to find.")
        let description = try XCTUnwrap(input["description"] as? String)
        for context in ["Make the primary action", "Example App", "com.example.app", "Design review", "https://example.com/design", "width 120", "height 80", "2026-10-15"] {
            XCTAssertTrue(description.contains(context), "Missing context: \(context)")
        }
        for request in requests {
            let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(text.contains("/Users/example/private-project"))
            XCTAssertFalse(text.contains("ORIGINAL-PRIVATE-PIXELS"))
            XCTAssertFalse(text.contains("screenshot-original.png"))
            XCTAssertFalse(text.contains("PRIVATE-INSTRUCTION-CONTENT"))
            XCTAssertFalse(text.contains("private-username"))
            XCTAssertFalse(text.contains("private-password"))
        }
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), token)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), token)
        let upload = requests[2]
        XCTAssertEqual(upload.httpMethod, "PUT")
        XCTAssertEqual(upload.url?.host, "uploads.example.test")
        XCTAssertNil(upload.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(upload.value(forHTTPHeaderField: "x-upload-fixture"), "signed-value")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(upload.httpBody, png)
        XCTAssertEqual(try graphInput(requests[3])["issueId"] as? String, "linear-issue-42")
        let persisted = try readReceipt()
        XCTAssertTrue(persisted.complete)
        XCTAssertEqual(persisted.issueURL.absoluteString, "https://linear.app/example/issue/DES-42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud-delivery-attempt.json").path))
        XCTAssertEqual(network.remainingSteps, 0)
    }

    func testPartialLinearAttachmentRetryUsesDurableIssueAndUploadedAsset() async throws {
        try makeBundle()
        let destination = linearDestination()
        var steps = linearSuccess()
        steps[3] = .json(["errors": [["message": "fixture failure"]], "data": NSNull()])
        network.enqueue(steps)

        do {
            _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)
            XCTFail("Attachment failure should remain visible")
        } catch let error as CloudDeliveryError {
            XCTAssertEqual(error.receipt?.issueKey, "DES-42")
            XCTAssertEqual(error.receipt?.issueURL.absoluteString, "https://linear.app/example/issue/DES-42")
            XCTAssertTrue(error.canRetry)
        }
        let partial = try readReceipt()
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.uploadedAssets["screenshot.png"]?.absoluteString, "https://uploads.linear.app/fixture.png")
        XCTAssertTrue(partial.attachedFiles.isEmpty)
        network.enqueue([.json(["data": ["attachmentCreate": ["success": true]]])])

        // A new client proves recovery uses disk rather than in-memory state.
        let receipt = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)

        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.issueID, partial.issueID)
        let requests = network.requests
        XCTAssertEqual(requests.count, 5)
        let lastInput = try graphInput(requests[4])
        XCTAssertEqual(lastInput["issueId"] as? String, "linear-issue-42")
        XCTAssertEqual(lastInput["url"] as? String, "https://uploads.linear.app/fixture.png")
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" && graphQuery($0).contains("issueCreate(") }.count, 1)
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(network.remainingSteps, 0)
    }

    func testCompletedReceiptReturnsWithoutNetworkOrDuplicateIssue() async throws {
        try makeBundle()
        let destination = linearDestination()
        var receipt = CloudDeliveryReceipt(destinationID: destination.id, provider: .linear, issueID: "existing-id", issueKey: "DES-9", issueURL: URL(string: "https://linear.app/example/issue/DES-9")!)
        receipt.complete = true
        receipt.attachedFiles = ["screenshot.png"]
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("cloud-delivery.json"))

        let returned = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)

        XCTAssertEqual(returned.issueID, "existing-id")
        XCTAssertTrue(returned.complete)
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testAmbiguousCreationKeepsAttemptAndBlocksAnotherPOST() async throws {
        try makeBundle()
        let destination = linearDestination()
        network.enqueue([.failure(URLError(.timedOut))])

        do {
            _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)
            XCTFail("A timeout cannot confirm creation")
        } catch let error as CloudDeliveryError {
            XCTAssertTrue(error.localizedDescription.contains("could not be confirmed"))
            XCTAssertFalse(error.canRetry)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud-delivery-attempt.json").path))

        do {
            _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)
            XCTFail("An ambiguous attempt must not be recreated")
        } catch let error as CloudDeliveryError {
            XCTAssertTrue(error.localizedDescription.contains("will not create a duplicate"))
            XCTAssertFalse(error.canRetry)
        }
        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(network.requests.first?.httpMethod, "POST")
    }

    func testJiraSendUsesADFAndMultipartWithClassicTokenAuthentication() async throws {
        try makeBundle()
        network.enqueue([
            .json(["startAt": 0, "total": 1, "fields": [["fieldId": "summary", "name": "Summary", "required": true, "hasDefaultValue": false]]]),
            .json(["enabled": true, "uploadLimit": 1_000_000]),
            .json(["id": "10042", "key": "APP-42"], status: 201),
            .json(["fields": ["attachment": []]]),
            .json([["id": "attachment-1", "filename": "screenshot.png"]])
        ])

        let receipt = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: jiraDestination(), token: token)

        XCTAssertTrue(receipt.complete)
        XCTAssertEqual(receipt.issueURL.absoluteString, "https://example.atlassian.net/browse/APP-42")
        let requests = network.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].url?.path, "/rest/api/3/issue/createmeta/10000/issuetypes/10001")
        XCTAssertEqual(requests[2].url?.path, "/rest/api/3/issue")
        XCTAssertEqual(requests[2].httpMethod, "POST")
        let body = try jsonObject(requests[2])
        let fields = try XCTUnwrap(body["fields"] as? [String: Any])
        XCTAssertEqual((fields["project"] as? [String: String])?["id"], "10000")
        XCTAssertEqual((fields["issuetype"] as? [String: String])?["id"], "10001")
        let document = try XCTUnwrap(fields["description"] as? [String: Any])
        XCTAssertEqual(document["type"] as? String, "doc")
        XCTAssertEqual(document["version"] as? Int, 1)
        let paragraphs = try XCTUnwrap(document["content"] as? [[String: Any]])
        let text = paragraphs.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Make the primary action easier to find."))
        XCTAssertTrue(text.contains("https://example.com/design"))
        XCTAssertTrue(text.contains("Marked region: x 20, y 30, width 120, height 80"))
        XCTAssertFalse(text.contains("/Users/example/private-project"))
        let upload = requests[4]
        XCTAssertEqual(upload.url?.path, "/rest/api/3/issue/10042/attachments")
        XCTAssertEqual(upload.value(forHTTPHeaderField: "X-Atlassian-Token"), "no-check")
        let contentType = try XCTUnwrap(upload.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Markup-"))
        let multipart = String(decoding: upload.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(multipart.contains("name=\"file\"; filename=\"screenshot.png\""))
        XCTAssertTrue(multipart.contains("Content-Type: image/png\r\n\r\n"))
        XCTAssertTrue(multipart.contains("ANNOTATED-FIXTURE"))
        XCTAssertFalse(multipart.contains("ORIGINAL-PRIVATE-PIXELS"))
        XCTAssertFalse(multipart.contains(token))
        let authorization = "Basic " + Data("person@example.com:\(token)".utf8).base64EncodedString()
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == authorization })
        XCTAssertTrue(try readReceipt().complete)
        XCTAssertEqual(network.remainingSteps, 0)
    }

    func testInvalidJiraSitesAreRejectedBeforeAnyNetworkRequest() async throws {
        let invalid = [
            "http://example.atlassian.net", "https://evil.example", "https://atlassian.net",
            "https://example.atlassian.net.evil.example", "https://user:password@example.atlassian.net",
            "https://example.atlassian.net/projects/APP", "https://example.atlassian.net?site=other",
            "https://example.atlassian.net#fragment", "https://example.atlassian.net:8443"
        ]
        let client = CloudFeedbackClient(session: session)
        for site in invalid {
            var destination = jiraDestination()
            destination.siteURL = site
            do {
                _ = try await client.catalog(for: destination, token: token)
                XCTFail("Should reject \(site)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Jira Cloud site"), "Unexpected rejection for \(site): \(error)")
            }
        }
        XCTAssertTrue(network.requests.isEmpty)
        var valid = jiraDestination()
        valid.siteURL = "https://EXAMPLE.atlassian.net:443/"
        XCTAssertEqual(try valid.validatedSiteURL().absoluteString, "https://example.atlassian.net")
    }

    func testTraversalAndOriginalScreenshotNamesNeverReachNetwork() async throws {
        let client = CloudFeedbackClient(session: session)
        for name in ["../screenshot.png", "screenshot-original.png", "/tmp/screenshot.png"] {
            try makeBundle(annotatedName: name)
            do {
                _ = try await client.send(bundleURL: directory, destination: linearDestination(), token: token)
                XCTFail("Should reject \(name)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("invalid annotated screenshot"))
            }
        }
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testScreenshotSymlinkCannotUploadOriginalImage() async throws {
        try makeBundle()
        let screenshotURL = directory.appendingPathComponent("screenshot.png")
        try FileManager.default.removeItem(at: screenshotURL)
        try FileManager.default.createSymbolicLink(at: screenshotURL, withDestinationURL: directory.appendingPathComponent("screenshot-original.png"))

        do {
            _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: linearDestination(), token: token)
            XCTFail("A symlink must not be treated as an annotated screenshot")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("annotated screenshot"))
        }
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testRequiredJiraCustomFieldsStopBeforeCreatingAnIssue() async throws {
        try makeBundle()
        network.enqueue([.json(["startAt": 0, "total": 2, "fields": [
            ["fieldId": "summary", "name": "Summary", "required": true, "hasDefaultValue": false],
            ["fieldId": "customfield_10050", "name": "Customer", "required": true, "hasDefaultValue": false]
        ]])])

        do {
            _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: jiraDestination(), token: token)
            XCTFail("Missing required fields must not create an incomplete issue")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("requires Customer"))
        }
        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(network.requests.first?.httpMethod, "GET")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud-delivery-attempt.json").path))
    }

    func testJiraReceiptCannotResumeAgainstAnotherTenantOrUnsafeIssueURL() async throws {
        try makeBundle()
        let destination = jiraDestination()
        let invalidURLs = [
            "https://other.atlassian.net/browse/APP-42",
            "http://example.atlassian.net/browse/APP-42",
            "https://user:password@example.atlassian.net/browse/APP-42",
            "https://example.atlassian.net:8443/browse/APP-42"
        ]
        for rawURL in invalidURLs {
            var receipt = CloudDeliveryReceipt(destinationID: destination.id, provider: .jira, issueID: "10042", issueKey: "APP-42", issueURL: URL(string: rawURL)!)
            // Even already-completed receipts must not expose an unsafe issue link.
            receipt.complete = true
            try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("cloud-delivery.json"))
            do {
                _ = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)
                XCTFail("Should reject receipt URL \(rawURL)")
            } catch let error as CloudDeliveryError {
                XCTAssertNil(error.receipt)
                XCTAssertFalse(error.canRetry)
            }
        }
        var valid = CloudDeliveryReceipt(destinationID: destination.id, provider: .jira, issueID: "10042", issueKey: "APP-42", issueURL: URL(string: "https://example.atlassian.net/browse/APP-42")!)
        valid.complete = true
        try JSONEncoder().encode(valid).write(to: directory.appendingPathComponent("cloud-delivery.json"))
        let receipt = try await CloudFeedbackClient(session: session).send(bundleURL: directory, destination: destination, token: token)
        XCTAssertEqual(receipt.issueKey, "APP-42")
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testLinearCatalogPaginatesTeamsAndUsesSelectedTeamsProjects() async throws {
        network.enqueue([
            .json(["data": ["organization": ["name": "Example workspace"]]]),
            .json(["data": ["teams": ["nodes": [["id": "team-other", "name": "Other"]], "pageInfo": ["hasNextPage": true, "endCursor": "team-cursor"]]]]),
            .json(["data": ["teams": ["nodes": [["id": "team-design", "name": "Design"]], "pageInfo": ["hasNextPage": false, "endCursor": "last-team"]]]]),
            .json(["data": ["team": ["projects": ["nodes": [["id": "project-mac", "name": "Mac app"]], "pageInfo": ["hasNextPage": false, "endCursor": "last-project"]]]]])
        ])

        let catalog = try await CloudFeedbackClient(session: session).catalog(for: linearDestination(), token: token)

        XCTAssertEqual(catalog.workspaceName, "Example workspace")
        XCTAssertEqual(catalog.teams.map(\.id), ["team-design", "team-other"])
        XCTAssertEqual(catalog.projects, [DestinationOption(id: "project-mac", name: "Mac app")])
        XCTAssertTrue(catalog.issueTypes.isEmpty)
        let requests = network.requests
        XCTAssertEqual(requests.count, 4)
        let secondPage = try XCTUnwrap(jsonObject(requests[2])["variables"] as? [String: Any])
        XCTAssertEqual(secondPage["after"] as? String, "team-cursor")
        let projectVariables = try XCTUnwrap(jsonObject(requests[3])["variables"] as? [String: Any])
        XCTAssertEqual(projectVariables["team"] as? String, "team-design")
        XCTAssertEqual(network.remainingSteps, 0)
    }

    private func makeBundle(annotatedName: String = "screenshot.png", browserURL: String = "https://example.com/design") throws {
        let app = FeedbackMetadata.AppMetadata(bundleId: "com.example.app", name: "Example App", windowTitle: "Design review")
        let browser = BrowserPageContext(url: browserURL, title: "Design page", routeKey: "browser:example.com", routeName: "Example")
        let capture = FeedbackMetadata.CaptureMetadata(type: "liveArea/ownerWindow", screenshotSize: .init(width: 640, height: 480), region: .init(x: 20, y: 30, width: 120, height: 80))
        let metadata = FeedbackMetadata(
            id: "fixture-feedback", schemaVersion: 4, createdAt: "2026-10-15T10:00:00Z", app: app, browser: browser,
            project: .init(root: "/Users/example/private-project", feedbackPath: ".markup/feedback"), capture: capture,
            assets: .init(annotatedScreenshot: annotatedName, originalScreenshot: "screenshot-original.png"),
            captures: [.init(index: 1, label: nil, note: "Make the primary action easier to find.", visibleText: ["Save"], app: app, browser: browser, capture: capture, assets: .init(annotatedScreenshot: annotatedName, originalScreenshot: "screenshot-original.png"))]
        )
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("metadata.json"))
        try png.write(to: directory.appendingPathComponent("screenshot.png"))
        try Data("ORIGINAL-PRIVATE-PIXELS".utf8).write(to: directory.appendingPathComponent("screenshot-original.png"))
        try Data("PRIVATE-INSTRUCTION-CONTENT /Users/example/private-project".utf8).write(to: directory.appendingPathComponent("instruction.md"))
    }

    private func linearDestination() -> FeedbackDestination {
        var destination = FeedbackDestination(provider: .linear, name: "Design")
        destination.teamID = "team-design"
        destination.projectID = "project-mac"
        return destination
    }

    private func jiraDestination() -> FeedbackDestination {
        var destination = FeedbackDestination(provider: .jira, name: "App project")
        destination.siteURL = "https://example.atlassian.net"
        destination.email = "person@example.com"
        destination.projectID = "10000"
        destination.issueTypeID = "10001"
        return destination
    }

    private func linearSuccess() -> [CloudMockResponse] {
        [
            .json(["data": ["issueCreate": ["success": true, "issue": ["id": "linear-issue-42", "identifier": "DES-42", "url": "https://linear.app/example/issue/DES-42"]]]]),
            .json(["data": ["fileUpload": ["success": true, "uploadFile": ["uploadUrl": "https://uploads.example.test/fixture", "assetUrl": "https://uploads.linear.app/fixture.png", "headers": [["key": "x-upload-fixture", "value": "signed-value"]]]]]]),
            .success(Data()),
            .json(["data": ["attachmentCreate": ["success": true]]])
        ]
    }

    private func readReceipt() throws -> CloudDeliveryReceipt {
        try JSONDecoder().decode(CloudDeliveryReceipt.self, from: Data(contentsOf: directory.appendingPathComponent("cloud-delivery.json")))
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    private func graphInput(_ request: URLRequest) throws -> [String: Any] {
        let variables = try XCTUnwrap(jsonObject(request)["variables"] as? [String: Any])
        return try XCTUnwrap(variables["input"] as? [String: Any])
    }

    private func graphQuery(_ request: URLRequest) -> String {
        guard let body = request.httpBody,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return "" }
        return object["query"] as? String ?? ""
    }
}

/// All requests are intercepted. Unexpected requests fail locally rather than
/// reaching a real provider. A per-session ID keeps parallel tests isolated.
private final class CloudMockNetwork {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var queued: [CloudMockResponse] = []

    var requests: [URLRequest] { lock.withLock { recorded } }
    var remainingSteps: Int { lock.withLock { queued.count } }

    func makeSession() -> URLSession {
        CloudMockURLProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Markup-Test-ID": id]
        return URLSession(configuration: configuration)
    }

    func enqueue(_ responses: [CloudMockResponse]) {
        lock.withLock { queued.append(contentsOf: responses) }
    }

    func response(to incoming: URLRequest) -> CloudMockResponse {
        var request = incoming
        if request.httpBody == nil, let stream = incoming.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            request.httpBody = body
        }
        return lock.withLock {
            recorded.append(request)
            guard !queued.isEmpty else { return .failure(URLError(.resourceUnavailable)) }
            return queued.removeFirst()
        }
    }

    func unregister() { CloudMockURLProtocol.unregister(id) }
}

private struct CloudMockResponse {
    var status = 200
    var body = Data()
    var error: Error?

    static func json(_ object: Any, status: Int = 200) -> Self {
        Self(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    static func success(_ data: Data) -> Self { Self(body: data) }
    static func failure(_ error: Error) -> Self { Self(error: error) }
}

private final class CloudMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var networks: [String: CloudMockNetwork] = [:]

    static func register(_ network: CloudMockNetwork) {
        lock.withLock { networks[network.id] = network }
    }

    static func unregister(_ id: String) {
        _ = lock.withLock { networks.removeValue(forKey: id) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Markup-Test-ID") ?? ""
        guard let network = Self.lock.withLock({ Self.networks[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let result = network.response(to: request)
        if let error = result.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
