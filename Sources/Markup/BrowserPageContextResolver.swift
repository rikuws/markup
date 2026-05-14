import AppKit
import ApplicationServices
import Foundation

struct RouteTarget {
    var key: String
    var name: String
    var browserPage: BrowserPageContext?
}

enum RouteTargetResolver {
    static func target(for app: NSRunningApplication, windowTitle: String? = nil) -> RouteTarget {
        let bundleId = app.bundleIdentifier ?? "unknown.bundle"
        let appName = app.localizedName ?? "Unknown App"

        if let browserPage = BrowserPageContextResolver.context(
            for: app,
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle
        ) {
            return RouteTarget(key: browserPage.routeKey, name: browserPage.routeName, browserPage: browserPage)
        }

        return RouteTarget(key: bundleId, name: appName, browserPage: nil)
    }
}

enum BrowserPageContextResolver {
    static func context(
        for app: NSRunningApplication,
        appName: String,
        bundleId: String,
        windowTitle: String?
    ) -> BrowserPageContext? {
        guard isBrowser(bundleId) else { return nil }

        let scriptPage = scriptPageContext(bundleId: bundleId)
        let accessibilityURL = accessibilityDocumentURL(for: app.processIdentifier)
        let url = firstNonEmpty(scriptPage?.url, accessibilityURL)
        let title = firstNonEmpty(scriptPage?.title, cleanWindowTitle(windowTitle, appName: appName), appName) ?? appName
        let identity = routeIdentity(urlString: url, title: title, bundleId: bundleId)

        return BrowserPageContext(
            url: url,
            title: title,
            routeKey: identity.key,
            routeName: "\(appName) - \(identity.label)"
        )
    }

    private static func isBrowser(_ bundleId: String) -> Bool {
        safariBundleIds.contains(bundleId)
            || chromiumBundleIds.contains(bundleId)
            || firefoxBundleIds.contains(bundleId)
    }

    private static let safariBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview"
    ]

    private static let chromiumBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX"
    ]

    private static let firefoxBundleIds: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "app.zen-browser.zen"
    ]

    private static func scriptPageContext(bundleId: String) -> (url: String?, title: String?)? {
        let source: String?

        if safariBundleIds.contains(bundleId) {
            source = """
            tell application id "\(bundleId)"
                if not (exists front document) then return ""
                set pageURL to URL of front document
                set pageTitle to name of front document
                return pageURL & linefeed & pageTitle
            end tell
            """
        } else if chromiumBundleIds.contains(bundleId) {
            source = """
            tell application id "\(bundleId)"
                if not (exists front window) then return ""
                set activeTab to active tab of front window
                set pageURL to URL of activeTab
                set pageTitle to title of activeTab
                return pageURL & linefeed & pageTitle
            end tell
            """
        } else {
            source = nil
        }

        guard let source, let script = NSAppleScript(source: source) else {
            return nil
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue ?? ""
        if let error {
            NSLog("Markup: browser AppleScript lookup failed for \(bundleId): \(error)")
        }

        let parts = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !parts.isEmpty else { return nil }
        return (
            url: firstNonEmpty(parts.first),
            title: firstNonEmpty(parts.dropFirst().joined(separator: " "))
        )
    }

    private static func accessibilityDocumentURL(for pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow
        else {
            return nil
        }

        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXDocumentAttribute as CFString, &document) == .success,
              let value = document as? String
        else {
            return nil
        }

        return firstNonEmpty(value)
    }

    private static func routeIdentity(
        urlString: String?,
        title: String,
        bundleId: String
    ) -> (key: String, label: String) {
        if let urlString,
           let url = URL(string: urlString),
           let urlIdentity = urlRouteIdentity(url) {
            return (key: "browser:\(urlIdentity.key)", label: urlIdentity.label)
        }

        let titleSlug = slug(title)
        let fallback = titleSlug.isEmpty ? slug(bundleId) : titleSlug
        return (key: "browser-title:\(bundleId):\(fallback)", label: title)
    }

    private static func urlRouteIdentity(_ url: URL) -> (key: String, label: String)? {
        if url.isFileURL {
            let path = url.deletingLastPathComponent().standardizedFileURL.path
            guard !path.isEmpty else { return nil }
            return (key: "file:\(slug(path))", label: url.deletingLastPathComponent().lastPathComponent)
        }

        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        let hostWithPort: String
        if let port = url.port {
            hostWithPort = "\(host):\(port)"
        } else {
            hostWithPort = host
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
            .filter { !$0.isEmpty }

        if isLocalHost(host) {
            return (key: hostWithPort, label: hostWithPort)
        }

        if ["github.com", "gitlab.com", "bitbucket.org"].contains(host),
           pathComponents.count >= 2 {
            let project = "\(host)/\(pathComponents[0])/\(pathComponents[1])"
            return (key: project, label: project)
        }

        if host == "figma.com" && pathComponents.count >= 2 {
            let project = "\(host)/\(pathComponents[0])/\(pathComponents[1])"
            return (key: project, label: project)
        }

        if host == "docs.google.com" && pathComponents.count >= 3 {
            let document = "\(host)/\(pathComponents[0])/\(pathComponents[1])/\(pathComponents[2])"
            return (key: document, label: document)
        }

        return (key: hostWithPort, label: hostWithPort)
    }

    private static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func cleanWindowTitle(_ title: String?, appName: String) -> String? {
        guard var title = firstNonEmpty(title) else { return nil }
        for separator in [" - ", " — ", " – "] {
            let suffix = "\(separator)\(appName)"
            if title.hasSuffix(suffix) {
                title.removeLast(suffix.count)
                return firstNonEmpty(title)
            }
        }
        return title
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        firstNonEmpty(values)
    }

    private static func firstNonEmpty<S: Sequence>(_ values: S) -> String? where S.Element == String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func slug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
