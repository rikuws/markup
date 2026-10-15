import AppKit
import SwiftUI

struct FeedbackDeliveryJob: Identifiable {
    let id = UUID()
    let routeKey: String
    let routeName: String
    let bundleURL: URL
    let destination: FeedbackDestination
    var receipt: CloudDeliveryReceipt?
    var error: String?
    var isSending = false
    var canRetry = true
}

@MainActor
final class FeedbackDeliveryModel: ObservableObject {
    @Published var jobs: [FeedbackDeliveryJob]
    @Published private(set) var isSending = false
    private let settingsStore: SettingsStore
    private let client = CloudFeedbackClient()

    init(jobs: [FeedbackDeliveryJob], settingsStore: SettingsStore) {
        self.jobs = jobs
        self.settingsStore = settingsStore
    }

    func send(jobID: UUID? = nil) {
        guard !isSending else { return }
        isSending = true
        Task { @MainActor in
            defer { self.isSending = false }
            for index in jobs.indices where jobID == nil || jobs[index].id == jobID {
                guard jobs[index].receipt?.complete != true else { continue }
                jobs[index].isSending = true
                jobs[index].error = nil
                let job = jobs[index]
                do {
                    // Disconnecting a destination also revokes queued sends.
                    guard let currentDestination = settingsStore.settings.destinations.first(where: { $0.id == job.destination.id }) else {
                        throw CloudDeliveryError(message: "This destination was disconnected. Your feedback is saved locally.", canRetry: false)
                    }
                    guard currentDestination.hasSameRouting(as: job.destination) else {
                        throw CloudDeliveryError(message: "This destination changed in Settings. This send belongs to its original team or project. Open the existing issue or your local copy to finish it there.", canRetry: false)
                    }
                    let token = try DestinationCredentials().token(for: job.destination.id)
                    let receipt = try await client.send(
                        bundleURL: job.bundleURL, destination: job.destination, token: token
                    )
                    jobs[index].receipt = receipt
                    settingsStore.rememberDestination(job.destination.id, for: job.routeKey)
                } catch {
                    if let deliveryError = error as? CloudDeliveryError, deliveryError.receipt != nil {
                        jobs[index].receipt = deliveryError.receipt
                    }
                    jobs[index].canRetry = (error as? CloudDeliveryError)?.canRetry ?? true
                    jobs[index].error = error.localizedDescription
                }
                jobs[index].isSending = false
            }
        }
    }
}

@MainActor
final class FeedbackDeliveryController: NSWindowController, NSWindowDelegate {
    let model: FeedbackDeliveryModel
    var onClose: (() -> Void)?

    init(jobs: [FeedbackDeliveryJob], settingsStore: SettingsStore) {
        model = FeedbackDeliveryModel(jobs: jobs, settingsStore: settingsStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Send Feedback"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: FeedbackDeliveryView(
            model: model, onDone: { [weak self] in self?.window?.performClose(nil) }
        ))
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isSending }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct FeedbackDeliveryView: View {
    @ObservedObject var model: FeedbackDeliveryModel
    var onDone: () -> Void

    private var isComplete: Bool { !model.jobs.isEmpty && model.jobs.allSatisfy { $0.receipt?.complete == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.isSending ? "Sending feedback…" : isComplete ? "Feedback sent" : "Feedback saved on this Mac")
                    .font(.title2.weight(.semibold))
                Text(model.isSending ? "Your notes and annotated screenshots are on their way." : "A local copy of every capture is safe in its project folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.jobs) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                if job.isSending {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: job.error != nil ? "exclamationmark.circle" : job.receipt?.complete == true ? "checkmark.circle.fill" : "clock")
                                        .foregroundStyle(job.error != nil ? Color.orange : Color.secondary)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(job.routeName).fontWeight(.medium)
                                    Text("\(job.destination.provider.displayName) · \(job.destination.name)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            if let error = job.error {
                                Text(error).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                if let receipt = job.receipt {
                                    Link("Open \(receipt.issueKey)", destination: receipt.issueURL)
                                }
                                Button("Show Local Copy") {
                                    NSWorkspace.shared.activateFileViewerSelecting([job.bundleURL])
                                }
                                Spacer()
                                if job.error != nil && job.canRetry {
                                    Button("Try Again") { model.send(jobID: job.id) }
                                        .disabled(model.isSending)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            Divider()
            HStack {
                Label("Local copy kept", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSending)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
