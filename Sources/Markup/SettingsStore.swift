import AppKit
import Foundation

final class SettingsStore: ObservableObject {
    @Published private(set) var settings: MarkupSettings

    var onHotKeyChange: (() -> Void)?

    private let settingsURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Markup", isDirectory: true)
        settingsURL = directory.appendingPathComponent("settings.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(MarkupSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MarkupSettings()
        }
    }

    func route(for bundleId: String) -> AppRoute? {
        settings.routes.first { $0.bundleId == bundleId }
    }

    func upsertRoute(bundleId: String, appName: String, projectRoot: URL, feedbackPath: String) {
        var next = settings
        let normalizedPath = feedbackPath.trimmedFeedbackPath
        let now = Date()

        if let index = next.routes.firstIndex(where: { $0.bundleId == bundleId }) {
            next.routes[index].appName = appName
            next.routes[index].projectRoot = projectRoot.path
            next.routes[index].feedbackPath = normalizedPath
            next.routes[index].updatedAt = now
        } else {
            next.routes.append(
                AppRoute(
                    bundleId: bundleId,
                    appName: appName,
                    projectRoot: projectRoot.path,
                    feedbackPath: normalizedPath,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        settings = next
        save()
    }

    func removeRoute(bundleId: String) {
        var next = settings
        next.routes.removeAll { $0.bundleId == bundleId }
        settings = next
        save()
    }

    func updateHotKey(_ hotKey: HotKeySettings) {
        guard settings.hotKey != hotKey else { return }
        var next = settings
        next.hotKey = hotKey.normalized
        settings = next
        save()
        onHotKeyChange?()
    }

    func updateTopNotchEnabled(_ enabled: Bool) {
        guard settings.topNotchEnabled != enabled else { return }
        var next = settings
        next.topNotchEnabled = enabled
        settings = next
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension String {
    var trimmedFeedbackPath: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? ".markup/feedback" : trimmed
        let components = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        return components.isEmpty ? ".markup/feedback" : components.joined(separator: "/")
    }
}

extension HotKeySettings {
    var normalized: HotKeySettings {
        var copy = self
        copy.key = String(key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(1))
        if copy.key.isEmpty {
            copy.key = "M"
        }
        return copy
    }
}
