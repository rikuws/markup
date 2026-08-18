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
    var topNotchEnabled = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case hotKey
        case routes
        case topNotchEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotKey = try container.decodeIfPresent(HotKeySettings.self, forKey: .hotKey) ?? HotKeySettings()
        routes = try container.decodeIfPresent([AppRoute].self, forKey: .routes) ?? []
        topNotchEnabled = try container.decodeIfPresent(Bool.self, forKey: .topNotchEnabled) ?? true
    }
}

struct CaptureRegion: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

struct BrowserPageContext: Codable, Equatable {
    var url: String?
    var title: String
    var routeKey: String
    var routeName: String
}

/// The window an area was drawn on top of, resolved by hit-testing the
/// on-screen window list at the drag origin (front-to-back). `nil` owner
/// means the area sits on the desktop (or on nothing routable).
struct AreaOwner {
    var appName: String
    var bundleId: String
    var windowTitle: String
    var processIdentifier: pid_t
    var windowID: CGWindowID?
    /// Global CG coordinates (origin at the top-left of the primary display).
    var windowBounds: CGRect
    var browserPage: BrowserPageContext?

    var routeKey: String {
        browserPage?.routeKey ?? bundleId
    }

    var routeName: String {
        browserPage?.routeName ?? appName
    }
}

/// One glass rectangle on the live screen. Unlike a 1.x shot, an area has
/// no pixels until save time — it is a place, an owner, and a note.
final class MarkupArea {
    let id = UUID()
    let createdAt = Date()

    /// Global CG coordinates (origin at the top-left of the primary display).
    var globalRect: CGRect
    var owner: AreaOwner?
    /// Committed note text (dictation finals and typed edits).
    var note = ""
    /// In-flight dictation for this area, shown dimmed. Never saved as-is;
    /// it is committed into `note` when the target changes or the session ends.
    var volatileNote = ""

    init(globalRect: CGRect, owner: AreaOwner?) {
        self.globalRect = globalRect
        self.owner = owner
    }

    var routeKey: String {
        owner?.routeKey ?? MarkupArea.desktopRouteKey
    }

    var routeName: String {
        owner?.routeName ?? "Desktop"
    }

    var displayName: String {
        owner?.appName ?? "Desktop"
    }

    var hasNote: Bool {
        !combinedNote.isEmpty
    }

    /// Committed note plus any in-flight dictation, for save and display.
    var combinedNote: String {
        [note, volatileNote]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static let desktopRouteKey = "desktop"
}

/// The state of one live markup session: every area drawn so far and which
/// one currently receives dictation.
final class LiveMarkupDraft {
    static let maximumAreas = 12

    private(set) var areas: [MarkupArea] = []
    private(set) var activeAreaID: UUID?

    var activeArea: MarkupArea? {
        areas.first { $0.id == activeAreaID }
    }

    var canAddArea: Bool {
        areas.count < Self.maximumAreas
    }

    var isComplete: Bool {
        !areas.isEmpty && areas.allSatisfy { $0.hasNote }
    }

    var firstAreaMissingNote: MarkupArea? {
        areas.first { !$0.hasNote }
    }

    @discardableResult
    func addArea(globalRect: CGRect, owner: AreaOwner?) -> MarkupArea? {
        guard canAddArea else { return nil }
        let area = MarkupArea(globalRect: globalRect, owner: owner)
        areas.append(area)
        activeAreaID = area.id
        return area
    }

    func activate(_ id: UUID) {
        guard areas.contains(where: { $0.id == id }) else { return }
        activeAreaID = id
    }

    func removeArea(id: UUID) {
        areas.removeAll { $0.id == id }
        if activeAreaID == id {
            activeAreaID = areas.last?.id
        }
    }

    func index(of area: MarkupArea) -> Int {
        (areas.firstIndex { $0.id == area.id } ?? 0) + 1
    }

    /// Areas grouped by route key, preserving creation order inside and
    /// across groups. Each group becomes one feedback bundle at save time.
    func areasByRoute() -> [(routeKey: String, areas: [MarkupArea])] {
        var order: [String] = []
        var groups: [String: [MarkupArea]] = [:]
        for area in areas {
            let key = area.routeKey
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(area)
        }
        return order.map { (routeKey: $0, areas: groups[$0] ?? []) }
    }
}

/// One area's pixels, captured at save time.
struct AreaCapture {
    enum Source: String {
        /// The owning window was captured whole; `region` marks the area inside it.
        case ownerWindow
        /// The owning window's on-screen bounds were captured from the display.
        case displayRect
        /// Only the area's own pixels could be captured; `region` covers the image.
        case areaOnly
    }

    var area: MarkupArea
    var image: NSImage
    var region: CaptureRegion
    var source: Source
}

struct FeedbackAssetNames {
    static let instruction = "instruction.md"
    static let metadata = "metadata.json"
    static let annotatedScreenshot = "screenshot.png"
    static let originalScreenshot = "screenshot-original.png"

    static func annotatedScreenshot(for index: Int) -> String {
        index <= 1 ? annotatedScreenshot : "screenshot-\(index).png"
    }

    static func originalScreenshot(for index: Int) -> String {
        index <= 1 ? originalScreenshot : "screenshot-original-\(index).png"
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
    }

    struct CaptureAssetsMetadata: Codable {
        var annotatedScreenshot: String
        var originalScreenshot: String
    }

    struct CaptureItemMetadata: Codable {
        var index: Int
        var label: String?
        /// Schema v4: the per-area note. 1.x shared one note across shots;
        /// live areas each carry their own.
        var note: String?
        /// Visible UI copy OCR'd from the marked region at save time, for
        /// agents. Not used as dictation vocabulary.
        var visibleText: [String]?
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
