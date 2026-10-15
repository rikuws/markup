import Foundation
import XCTest
@testable import Markup

final class DestinationSettingsTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkupSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        settingsURL = temporaryDirectory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testLegacySettingsKeepCapturePreferencesAndStartWithLocalDestinations() throws {
        let legacySettings = """
        {
          "hotKey": {"key": "K", "command": true, "shift": false, "option": true, "control": false},
          "routes": [{
            "bundleId": "com.example.editor",
            "appName": "Example Editor",
            "projectRoot": "/tmp/markup-example",
            "feedbackPath": ".feedback",
            "createdAt": "2026-10-01T10:00:00Z",
            "updatedAt": "2026-10-02T10:00:00Z"
          }],
          "topNotchEnabled": false,
          "dictationEngine": "parakeet"
        }
        """
        try Data(legacySettings.utf8).write(to: settingsURL)

        let store = SettingsStore(settingsURL: settingsURL)

        XCTAssertEqual(store.settings.hotKey.key, "K")
        XCTAssertTrue(store.settings.hotKey.option)
        XCTAssertFalse(store.settings.hotKey.shift)
        XCTAssertFalse(store.settings.topNotchEnabled)
        XCTAssertEqual(store.settings.dictationEngine, .parakeet)
        XCTAssertEqual(store.settings.routes.count, 1)
        XCTAssertEqual(store.route(for: "com.example.editor")?.feedbackPath, ".feedback")
        XCTAssertEqual(store.route(for: "com.example.editor")?.projectRoot, "/tmp/markup-example")
        XCTAssertTrue(store.settings.destinations.isEmpty)
        XCTAssertTrue(store.settings.destinationByRoute.isEmpty)
        XCTAssertNil(store.suggestedDestination(for: "com.example.editor"))
    }

    func testDestinationsAndRouteChoicesSurviveReloadWithoutChangingLocalPaths() throws {
        let store = SettingsStore(settingsURL: settingsURL)
        let linear = makeLinear(name: "Design team")
        let jira = makeJira(name: "Client project")
        let browserRoute = "browser:example.com/design"

        store.upsertRoute(bundleId: "com.example.editor", appName: "Editor", projectRoot: temporaryDirectory, feedbackPath: ".markup/editor")
        store.upsertRoute(bundleId: browserRoute, appName: "Client", projectRoot: temporaryDirectory, feedbackPath: ".markup/client")
        store.upsertDestination(linear)
        store.upsertDestination(jira)
        store.rememberDestination(linear.id, for: "com.example.editor")
        store.rememberDestination(jira.id, for: browserRoute)

        let reloaded = SettingsStore(settingsURL: settingsURL)

        XCTAssertEqual(reloaded.settings.destinations, [linear, jira])
        XCTAssertEqual(reloaded.suggestedDestination(for: "com.example.editor"), linear)
        XCTAssertEqual(reloaded.suggestedDestination(for: browserRoute), jira)
        XCTAssertEqual(reloaded.route(for: "com.example.editor")?.feedbackPath, ".markup/editor")
        XCTAssertEqual(reloaded.route(for: browserRoute)?.feedbackPath, ".markup/client")
        XCTAssertEqual(reloaded.route(for: browserRoute)?.projectRootURL.standardizedFileURL, temporaryDirectory.standardizedFileURL)

        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let destinations = try XCTUnwrap(persisted["destinations"] as? [[String: Any]])
        XCTAssertEqual(destinations.count, 2)
        for destination in destinations {
            XCTAssertNil(destination["token"])
            XCTAssertNil(destination["apiKey"])
            XCTAssertNil(destination["credential"])
        }
    }

    func testChoosingLocalClearsOnlyThatRoutesRememberedDestination() {
        let store = SettingsStore(settingsURL: settingsURL)
        let destination = makeLinear()
        store.upsertDestination(destination)
        store.rememberDestination(destination.id, for: "route-a")
        store.rememberDestination(destination.id, for: "route-b")

        store.rememberDestination(nil, for: "route-a")

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertNil(reloaded.suggestedDestination(for: "route-a"))
        XCTAssertNil(reloaded.settings.destinationByRoute["route-a"])
        XCTAssertEqual(reloaded.suggestedDestination(for: "route-b")?.id, destination.id)
        XCTAssertEqual(reloaded.settings.destinations, [destination])
    }

    func testDisconnectingDestinationRestoresLocalForItsRoutesAndKeepsOthers() {
        let store = SettingsStore(settingsURL: settingsURL)
        let linear = makeLinear()
        let jira = makeJira()
        store.upsertDestination(linear)
        store.upsertDestination(jira)
        store.rememberDestination(linear.id, for: "linear-route-a")
        store.rememberDestination(linear.id, for: "linear-route-b")
        store.rememberDestination(jira.id, for: "jira-route")

        store.removeDestination(id: linear.id)

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertNil(reloaded.suggestedDestination(for: "linear-route-a"))
        XCTAssertNil(reloaded.suggestedDestination(for: "linear-route-b"))
        XCTAssertNil(reloaded.settings.destinationByRoute["linear-route-a"])
        XCTAssertNil(reloaded.settings.destinationByRoute["linear-route-b"])
        XCTAssertEqual(reloaded.suggestedDestination(for: "jira-route"), jira)
        XCTAssertEqual(reloaded.settings.destinations, [jira])
    }

    func testRemovingRouteClearsItsChoiceWithoutDisconnectingSharedDestination() {
        let store = SettingsStore(settingsURL: settingsURL)
        let destination = makeLinear()
        store.upsertDestination(destination)
        store.upsertRoute(bundleId: "route-a", appName: "First", projectRoot: temporaryDirectory, feedbackPath: ".markup/first")
        store.upsertRoute(bundleId: "route-b", appName: "Second", projectRoot: temporaryDirectory, feedbackPath: ".markup/second")
        store.rememberDestination(destination.id, for: "route-a")
        store.rememberDestination(destination.id, for: "route-b")

        store.removeRoute(bundleId: "route-a")

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertNil(reloaded.route(for: "route-a"))
        XCTAssertNil(reloaded.suggestedDestination(for: "route-a"))
        XCTAssertEqual(reloaded.route(for: "route-b")?.feedbackPath, ".markup/second")
        XCTAssertEqual(reloaded.suggestedDestination(for: "route-b"), destination)
        XCTAssertEqual(reloaded.settings.destinations, [destination])
    }

    func testUpdatingDestinationRetainsItsIdentityAndExistingRouteChoices() {
        let store = SettingsStore(settingsURL: settingsURL)
        var destination = makeJira(name: "Old name")
        store.upsertDestination(destination)
        store.rememberDestination(destination.id, for: "route-a")

        destination.name = "New project"
        destination.projectID = "10200"
        destination.issueTypeID = "10004"
        store.upsertDestination(destination)

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertEqual(reloaded.settings.destinations.count, 1)
        XCTAssertEqual(reloaded.suggestedDestination(for: "route-a"), destination)
        XCTAssertEqual(reloaded.suggestedDestination(for: "route-a")?.projectID, "10200")
    }

    func testUnknownRememberedDestinationFallsBackToLocal() {
        let store = SettingsStore(settingsURL: settingsURL)
        store.rememberDestination(UUID(), for: "stale-route")

        let reloaded = SettingsStore(settingsURL: settingsURL)

        XCTAssertNil(reloaded.suggestedDestination(for: "stale-route"))
        XCTAssertNil(reloaded.suggestedDestination(for: "new-route"))
    }

    func testCosmeticDestinationEditsDoNotInvalidateAnAuthorizedRoute() {
        let original = makeJira()
        var renamed = original
        renamed.name = "A clearer name"
        renamed.workspaceName = "Our workspace"
        renamed.projectName = "Website"

        XCTAssertTrue(renamed.hasSameRouting(as: original))
        renamed.siteURL = "https://another.atlassian.net"
        XCTAssertFalse(renamed.hasSameRouting(as: original))
        renamed = original
        renamed.projectID = "different-project"
        XCTAssertFalse(renamed.hasSameRouting(as: original))
        renamed = original
        renamed.email = "another@example.com"
        XCTAssertFalse(renamed.hasSameRouting(as: original))
    }

    func testUnknownSimulatorDoesNotRememberAnotherGuestsDestination() {
        let store = SettingsStore(settingsURL: settingsURL)
        let destination = makeLinear()
        let unknown = "hosted-ask:simulator:iphone"
        let known = "simulator:com.example.guest"
        store.upsertDestination(destination)
        store.rememberDestination(destination.id, for: unknown)
        store.rememberDestination(destination.id, for: known)

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertNil(reloaded.settings.destinationByRoute[unknown])
        XCTAssertNil(reloaded.suggestedDestination(for: unknown))
        XCTAssertEqual(reloaded.suggestedDestination(for: known), destination)
        XCTAssertNil(reloaded.suggestedDestination(for: "com.example.guest"))
        XCTAssertNil(reloaded.suggestedDestination(for: "simulator:com.example.other"))
    }

    func testDeliveryRecoverySurvivesReloadWithoutRememberingAnAppRoute() {
        let store = SettingsStore(settingsURL: settingsURL)
        let first = temporaryDirectory.appendingPathComponent("first")
        let second = temporaryDirectory.appendingPathComponent("second")
        store.recordDeliveryBundle(first)
        store.recordDeliveryBundle(second)
        store.recordDeliveryBundle(first)

        let reloaded = SettingsStore(settingsURL: settingsURL)
        XCTAssertEqual(reloaded.settings.recentDeliveryBundles, [first.path, second.path])
        XCTAssertTrue(reloaded.settings.routes.isEmpty)
        XCTAssertTrue(reloaded.settings.destinationByRoute.isEmpty)
    }

    private func makeLinear(name: String = "Linear workspace") -> FeedbackDestination {
        var destination = FeedbackDestination(provider: .linear, name: name)
        destination.teamID = "team-design"
        destination.projectID = "project-app"
        destination.workspaceName = "Example workspace"
        destination.teamName = "Design"
        destination.projectName = "Mac app"
        return destination
    }

    private func makeJira(name: String = "Jira project") -> FeedbackDestination {
        var destination = FeedbackDestination(provider: .jira, name: name)
        destination.siteURL = "https://example.atlassian.net"
        destination.email = "example@example.com"
        destination.projectID = "10100"
        destination.issueTypeID = "10001"
        destination.workspaceName = "example.atlassian.net"
        destination.projectName = "Client website"
        destination.issueTypeName = "Task"
        return destination
    }
}
