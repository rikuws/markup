import Foundation

struct FeedbackInboxProject {
    var id: String
    var title: String
    var feedbackDirectoryURL: URL
    var items: [FeedbackInboxItem]
}

struct FeedbackInboxItem {
    var id: String
    var title: String
    var createdAt: Date?
    var directoryURL: URL
    var instructionURL: URL
    var screenshotURL: URL?
}

final class FeedbackInbox {
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let isoFormatter = ISO8601DateFormatter()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func projects(for routes: [AppRoute]) -> [FeedbackInboxProject] {
        let groupedRoutes = Dictionary(grouping: routes) { route in
            route.feedbackDirectoryURL.standardizedFileURL.path
        }

        return groupedRoutes.values
            .compactMap { routes in
                guard let route = routes.sorted(by: routeSort).first else {
                    return nil
                }

                let feedbackDirectoryURL = route.feedbackDirectoryURL
                return FeedbackInboxProject(
                    id: feedbackDirectoryURL.standardizedFileURL.path,
                    title: projectTitle(for: route),
                    feedbackDirectoryURL: feedbackDirectoryURL,
                    items: items(in: feedbackDirectoryURL)
                )
            }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private func items(in feedbackDirectoryURL: URL) -> [FeedbackInboxItem] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: feedbackDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return children
            .compactMap(item(at:))
            .sorted {
                switch ($0.createdAt, $1.createdAt) {
                case let (lhs?, rhs?):
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
                }
            }
    }

    private func item(at directoryURL: URL) -> FeedbackInboxItem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }

        let instructionURL = directoryURL.appendingPathComponent(FeedbackAssetNames.instruction)
        let metadataURL = directoryURL.appendingPathComponent(FeedbackAssetNames.metadata)
        guard fileManager.fileExists(atPath: instructionURL.path),
              fileManager.fileExists(atPath: metadataURL.path)
        else {
            return nil
        }

        let metadata = loadMetadata(from: metadataURL)
        let createdAt = parseDate(metadata?.createdAt) ?? modificationDate(for: directoryURL)
        let id = metadata?.id.nonEmpty ?? directoryURL.lastPathComponent
        let note = userNote(from: instructionURL)
        let title = note.nonEmpty
            ?? metadata?.browser?.title.nonEmpty
            ?? metadata?.app?.windowTitle.nonEmpty
            ?? id

        return FeedbackInboxItem(
            id: id,
            title: title,
            createdAt: createdAt,
            directoryURL: directoryURL,
            instructionURL: instructionURL,
            screenshotURL: screenshotURL(for: directoryURL, metadata: metadata)
        )
    }

    private func loadMetadata(from url: URL) -> InboxMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? decoder.decode(InboxMetadata.self, from: data)
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        return isoFormatter.date(from: value)
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func userNote(from url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }

        let lines = contents.components(separatedBy: .newlines)
        guard let noteIndex = lines.firstIndex(where: { $0 == "User note:" }) else {
            return ""
        }

        var noteLines: [String] = []
        for line in lines.dropFirst(noteIndex + 1) {
            if line.hasPrefix("> ") {
                noteLines.append(String(line.dropFirst(2)))
            } else if line == ">" {
                noteLines.append("")
            } else if noteLines.isEmpty && line.isEmpty {
                continue
            } else {
                break
            }
        }

        return noteLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func screenshotURL(for directoryURL: URL, metadata: InboxMetadata?) -> URL? {
        let name = metadata?.assets?.annotatedScreenshot.nonEmpty ?? FeedbackAssetNames.annotatedScreenshot
        let url = directoryURL.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func projectTitle(for route: AppRoute) -> String {
        route.projectRootURL.lastPathComponent.nonEmpty ?? route.appName
    }

    private func routeSort(_ lhs: AppRoute, _ rhs: AppRoute) -> Bool {
        lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
    }
}

private struct InboxMetadata: Decodable {
    struct App: Decodable {
        var windowTitle: String?
    }

    struct Assets: Decodable {
        var annotatedScreenshot: String?
    }

    var id: String?
    var createdAt: String?
    var app: App?
    var browser: BrowserPageContext?
    var assets: Assets?
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
