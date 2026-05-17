import AppKit
import Foundation

struct HotKeySettings: Codable, Equatable {
    var key: String = "M"
    var command: Bool = true
    var shift: Bool = true
    var option: Bool = false
    var control: Bool = false

    var displayString: String {
        var parts: [String] = []
        if command { parts.append("\u{2318}") }
        if shift { parts.append("\u{21E7}") }
        if option { parts.append("\u{2325}") }
        if control { parts.append("\u{2303}") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }
}

struct AppRoute: Codable, Identifiable, Equatable {
    var id: String { bundleId }

    var bundleId: String
    var appName: String
    var projectRoot: String
    var feedbackPath: String
    var createdAt: Date
    var updatedAt: Date

    var projectRootURL: URL {
        URL(fileURLWithPath: projectRoot, isDirectory: true)
    }

    var feedbackDirectoryURL: URL {
        projectRootURL.appendingPathComponent(feedbackPath, isDirectory: true)
    }
}

struct MarkupSettings: Codable, Equatable {
    var hotKey = HotKeySettings()
    var routes: [AppRoute] = []
}

struct CaptureRegion: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct CapturedWindow {
    var image: NSImage
    var appName: String
    var bundleId: String
    var windowTitle: String
    var processIdentifier: pid_t
    var windowID: CGWindowID?
    var browserPage: BrowserPageContext?

    var routeKey: String {
        browserPage?.routeKey ?? bundleId
    }

    var routeName: String {
        browserPage?.routeName ?? appName
    }
}

struct BrowserPageContext: Codable, Equatable {
    var url: String?
    var title: String
    var routeKey: String
    var routeName: String
}

struct FeedbackAssetNames {
    static let instruction = "instruction.md"
    static let metadata = "metadata.json"
    static let annotatedScreenshot = "screenshot.png"
    static let originalScreenshot = "screenshot-original.png"
    static let recording = "recording.mov"

    static func annotatedScreenshot(for index: Int) -> String {
        index <= 1 ? annotatedScreenshot : "screenshot-\(index).png"
    }

    static func originalScreenshot(for index: Int) -> String {
        index <= 1 ? originalScreenshot : "screenshot-original-\(index).png"
    }
}

final class FeedbackDraft {
    static let maximumShots = 6

    var route: AppRoute?
    var note = ""
    var recordingURL: URL?
    private(set) var shots: [FeedbackDraftShot]

    init(primaryCapture: CapturedWindow, route: AppRoute?) {
        self.route = route
        shots = [FeedbackDraftShot(captured: primaryCapture)]
    }

    var primaryCapture: CapturedWindow {
        shots[0].captured
    }

    var canAddShot: Bool {
        shots.count < Self.maximumShots
    }

    var nextShotIndex: Int {
        min(shots.count + 1, Self.maximumShots)
    }

    var requiresRegions: Bool {
        recordingURL == nil
    }

    var isComplete: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresRegions || shots.allSatisfy { $0.region != nil })
    }

    @discardableResult
    func append(captured: CapturedWindow) -> FeedbackDraftShot? {
        guard canAddShot else { return nil }
        let shot = FeedbackDraftShot(captured: captured)
        shots.append(shot)
        return shot
    }

    func deleteShot(id: UUID) {
        guard let index = shots.firstIndex(where: { $0.id == id }), index > 0 else {
            return
        }
        shots.remove(at: index)
    }
}

final class FeedbackDraftShot {
    let id = UUID()
    var captured: CapturedWindow
    var region: CaptureRegion?
    var label = ""

    init(captured: CapturedWindow) {
        self.captured = captured
    }
}

struct FeedbackMetadata: Codable {
    struct AppMetadata: Codable {
        var bundleId: String
        var name: String
        var windowTitle: String
    }

    struct ProjectMetadata: Codable {
        var root: String
        var feedbackPath: String
    }

    struct SizeMetadata: Codable {
        var width: Int
        var height: Int
    }

    struct CaptureMetadata: Codable {
        var type: String
        var screenshotSize: SizeMetadata
        var region: CaptureRegion?
    }

    struct AssetsMetadata: Codable {
        var annotatedScreenshot: String
        var originalScreenshot: String
        var recording: String?
    }

    struct CaptureAssetsMetadata: Codable {
        var annotatedScreenshot: String
        var originalScreenshot: String
    }

    struct CaptureItemMetadata: Codable {
        var index: Int
        var label: String?
        var app: AppMetadata
        var browser: BrowserPageContext?
        var capture: CaptureMetadata
        var assets: CaptureAssetsMetadata
    }

    var id: String
    var schemaVersion: Int
    var createdAt: String
    var app: AppMetadata
    var browser: BrowserPageContext?
    var project: ProjectMetadata
    var capture: CaptureMetadata
    var assets: AssetsMetadata
    var captures: [CaptureItemMetadata]
}
