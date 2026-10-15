import AppKit
import Foundation

final class SettingsStore: ObservableObject {
    @Published private(set) var settings: MarkupSettings

    var onHotKeyChange: (() -> Void)?

    private let settingsURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(settingsURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Markup", isDirectory: true)
        self.settingsURL = settingsURL ?? directory.appendingPathComponent("settings.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: self.settingsURL),
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
        next.destinationByRoute.removeValue(forKey: bundleId)
        settings = next
        save()
    }

    func suggestedDestination(for routeKey: String) -> FeedbackDestination? {
        guard !HostedAppContext.isEphemeralRouteKey(routeKey) else { return nil }
        guard let id = settings.destinationByRoute[routeKey] else { return nil }
        return settings.destinations.first { $0.id == id }
    }

    func rememberDestination(_ id: UUID?, for routeKey: String) {
        guard !HostedAppContext.isEphemeralRouteKey(routeKey) else { return }
        var next = settings
        next.destinationByRoute[routeKey] = id
        settings = next
        save()
    }

    func upsertDestination(_ destination: FeedbackDestination) {
        var next = settings
        if let index = next.destinations.firstIndex(where: { $0.id == destination.id }) {
            next.destinations[index] = destination
        } else {
            next.destinations.append(destination)
        }
        settings = next
        save()
    }

    func recordDeliveryBundle(_ url: URL) {
        let path = url.standardizedFileURL.path
        var next = settings
        next.recentDeliveryBundles.removeAll { $0 == path }
        next.recentDeliveryBundles.insert(path, at: 0)
        next.recentDeliveryBundles = Array(next.recentDeliveryBundles.prefix(50))
        settings = next
        save()
    }

    func removeDestination(id: UUID) {
        var next = settings
        next.destinations.removeAll { $0.id == id }
        next.destinationByRoute = next.destinationByRoute.filter { $0.value != id }
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

    func updateDictationEngine(_ engine: TranscriptionEngineKind) {
        guard settings.dictationEngine != engine else { return }
        var next = settings
        next.dictationEngine = engine
        settings = next
        save()
        Task { @MainActor in
            if engine == .parakeet {
                ParakeetModelStatus.shared.ensureDownloaded()
            } else {
                await NoteDictationController.prewarm(engine: engine)
            }
        }
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
