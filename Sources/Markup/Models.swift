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
        var region: CaptureRegion
    }

    struct AssetsMetadata: Codable {
        var annotatedScreenshot: String
        var originalScreenshot: String
        var recording: String?
    }

    var id: String
    var createdAt: String
    var app: AppMetadata
    var browser: BrowserPageContext?
    var project: ProjectMetadata
    var capture: CaptureMetadata
    var assets: AssetsMetadata
}
