import AppKit
import Foundation

struct HotKeySettings: Codable, Equatable {
    var key: String = "P"
    var command: Bool = true
    var shift: Bool = true
    var option: Bool = false
    var control: Bool = false
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

struct PunchlistSettings: Codable, Equatable {
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
    var project: ProjectMetadata
    var capture: CaptureMetadata
    var assets: AssetsMetadata
}
