import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Nested runtimes (iOS Simulator, Android Emulator) own the Mac window, but
/// the app the user is actually looking at is a guest inside that window.
/// Routing by the host bundle ID would send every simulated app to the first
/// project that was ever chosen for Simulator.
enum HostedAppContextResolver {
    static let appleSimulatorBundleId = "com.apple.iphonesimulator"

    static func context(
        hostBundleId: String,
        appName: String,
        windowTitle: String,
        windowBounds: CGRect,
        processIdentifier: pid_t
    ) -> HostedAppContext? {
        if isAppleSimulator(bundleId: hostBundleId, appName: appName) {
            return simulatorContext(
                hostBundleId: hostBundleId,
                windowTitle: windowTitle,
                windowBounds: windowBounds,
                processIdentifier: processIdentifier
            )
        }

        if isAndroidEmulator(bundleId: hostBundleId, appName: appName) {
            return androidEmulatorContext(
                hostBundleId: hostBundleId,
                windowTitle: windowTitle
            )
        }

        return nil
    }

    // MARK: - Simulator

    private static func simulatorContext(
        hostBundleId: String,
        windowTitle: String,
        windowBounds: CGRect,
        processIdentifier: pid_t
    ) -> HostedAppContext {
        let title = accessibilityTitle(
            pid: processIdentifier,
            cgBounds: windowBounds,
            fallback: windowTitle
        )
        let devices = bootedDevices()
        let device = matchDevice(title: title, devices: devices)
        let guests = runningSimulatorGuests(deviceUDID: device?.udid)
        let guest = pickGuest(from: guests)

        if let guest {
            NSLog(
                "Markup: simulator guest \(guest.name) (\(guest.bundleId)) device='\(device?.name ?? title)' traced=\(guest.isDebugged)"
            )
            return HostedAppContext(
                hostKind: HostedAppContext.simulatorKind,
                hostBundleId: hostBundleId,
                deviceName: device?.name ?? firstNonEmpty(title),
                guestBundleId: guest.bundleId,
                guestName: guest.name,
                routeKey: "\(HostedAppContext.simulatorKind):\(guest.bundleId)",
                routeName: "\(guest.name) (Simulator)"
            )
        }

        let deviceName = device?.name ?? firstNonEmpty(title) ?? "Simulator"
        NSLog(
            "Markup: simulator guest unidentified device='\(deviceName)' guests=\(guests.count)"
        )
        return HostedAppContext(
            hostKind: HostedAppContext.simulatorKind,
            hostBundleId: hostBundleId,
            deviceName: deviceName,
            guestBundleId: nil,
            guestName: nil,
            routeKey: "\(HostedAppContext.ephemeralRoutePrefix)\(HostedAppContext.simulatorKind):\(slug(deviceName))",
            routeName: "Simulator — \(deviceName)"
        )
    }

    private static func androidEmulatorContext(
        hostBundleId: String,
        windowTitle: String
    ) -> HostedAppContext {
        let deviceName = firstNonEmpty(windowTitle) ?? "Android Emulator"
        NSLog("Markup: android emulator capture device='\(deviceName)'; asking where to save")
        return HostedAppContext(
            hostKind: HostedAppContext.androidEmulatorKind,
            hostBundleId: hostBundleId,
            deviceName: deviceName,
            guestBundleId: nil,
            guestName: nil,
            routeKey: "\(HostedAppContext.ephemeralRoutePrefix)\(HostedAppContext.androidEmulatorKind):\(slug(deviceName))",
            routeName: "Android Emulator — \(deviceName)"
        )
    }

    private static func isAppleSimulator(bundleId: String, appName: String) -> Bool {
        appleSimulatorBundleIds.contains(bundleId) || appName == "Simulator"
    }

    private static func isAndroidEmulator(bundleId: String, appName: String) -> Bool {
        androidEmulatorBundleIds.contains(bundleId)
            || appName == "Android Emulator"
            || appName.hasPrefix("qemu-system")
    }

    private static let appleSimulatorBundleIds: Set<String> = [
        appleSimulatorBundleId,
        "com.apple.WatchSimulator",
        "com.apple.tvsimulator",
        "com.apple.RealitySimulator"
    ]

    private static let androidEmulatorBundleIds: Set<String> = [
        "com.google.android.emulator"
    ]

    // MARK: - Booted devices

    private struct SimulatorDevice {
        var udid: String
        var name: String
        var runtimeLabel: String?
    }

    private static func bootedDevices() -> [SimulatorDevice] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { directory in
            let plistURL = directory.appendingPathComponent("device.plist")
            guard let plist = NSDictionary(contentsOf: plistURL), isBooted(plist["state"]) else {
                return nil
            }

            let udid = (plist["UDID"] as? String).flatMap(firstNonEmpty) ?? directory.lastPathComponent
            let name = (plist["name"] as? String).flatMap(firstNonEmpty) ?? udid
            return SimulatorDevice(
                udid: udid,
                name: name,
                runtimeLabel: runtimeLabel(from: plist["runtime"] as? String)
            )
        }
    }

    private static func isBooted(_ state: Any?) -> Bool {
        if let value = state as? Int {
            return value == 3
        }
        if let value = state as? NSNumber {
            return value.intValue == 3
        }
        if let value = state as? String {
            return value.caseInsensitiveCompare("Booted") == .orderedSame
        }
        return false
    }

    private static func runtimeLabel(from identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard parts.count >= 2 else {
            return last.replacingOccurrences(of: "-", with: " ")
        }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }

    private static func matchDevice(title: String, devices: [SimulatorDevice]) -> SimulatorDevice? {
        if devices.count == 1 {
            return devices[0]
        }

        let normalizedTitle = normalizeTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let exact = devices.filter { device in
            let name = normalizeTitle(device.name)
            guard !name.isEmpty else { return false }
            if normalizedTitle == name { return true }
            if normalizedTitle.hasPrefix(name + " - ") { return true }
            if let runtime = device.runtimeLabel {
                return normalizedTitle == normalizeTitle("\(device.name) - \(runtime)")
            }
            return false
        }
        if exact.count == 1 {
            return exact[0]
        }

        let prefix = devices.filter { device in
            let name = normalizeTitle(device.name)
            return !name.isEmpty && normalizedTitle.hasPrefix(name)
        }
        return prefix.count == 1 ? prefix[0] : nil
    }

    // MARK: - Guest processes

    private struct SimulatorGuest {
        var bundleId: String
        var name: String
        var isDebugged: Bool
    }

    private static func runningSimulatorGuests(deviceUDID: String?) -> [SimulatorGuest] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleURL = app.bundleURL else { return nil }
            let path = bundleURL.path
            guard path.contains("/CoreSimulator/Devices/"),
                  path.contains("/Containers/Bundle/Application/"),
                  bundleURL.pathExtension == "app"
            else {
                return nil
            }

            if let deviceUDID, udid(from: path) != deviceUDID {
                return nil
            }

            guard let bundleId = bundleIdentifier(for: app, bundleURL: bundleURL),
                  !shouldIgnoreGuest(bundleId: bundleId, name: app.localizedName ?? "", path: path)
            else {
                return nil
            }

            return SimulatorGuest(
                bundleId: bundleId,
                name: displayName(for: app, bundleURL: bundleURL),
                isDebugged: isTraced(app.processIdentifier)
            )
        }
    }

    private static func pickGuest(from guests: [SimulatorGuest]) -> SimulatorGuest? {
        if guests.isEmpty { return nil }
        if guests.count == 1 { return guests[0] }

        let traced = guests.filter(\.isDebugged)
        if traced.count == 1 { return traced[0] }

        // Several user apps are in memory and none is uniquely under a
        // debugger, so guessing would send feedback to the wrong project.
        return nil
    }

    private static func shouldIgnoreGuest(bundleId: String, name: String, path: String) -> Bool {
        if path.contains(".appex") { return true }
        if bundleId.hasPrefix("com.apple.") { return true }
        if ignoredGuestNames.contains(name) { return true }
        if name.hasSuffix("Extension") || name.hasSuffix("Widget") { return true }
        return false
    }

    private static let ignoredGuestNames: Set<String> = [
        "SpringBoard",
        "backboardd",
        "launchd_sim"
    ]

    private static func bundleIdentifier(for app: NSRunningApplication, bundleURL: URL) -> String? {
        if let bundleId = firstNonEmpty(app.bundleIdentifier) {
            return bundleId
        }
        let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        return firstNonEmpty(plist?["CFBundleIdentifier"] as? String)
    }

    private static func displayName(for app: NSRunningApplication, bundleURL: URL) -> String {
        if let name = firstNonEmpty(app.localizedName), name != app.bundleIdentifier {
            return name
        }
        let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        if let display = firstNonEmpty(plist?["CFBundleDisplayName"] as? String) {
            return display
        }
        if let name = firstNonEmpty(plist?["CFBundleName"] as? String) {
            return name
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    private static func udid(from path: String) -> String? {
        let marker = "/CoreSimulator/Devices/"
        guard let markerRange = path.range(of: marker) else { return nil }
        let rest = path[markerRange.upperBound...]
        guard let end = rest.firstIndex(of: "/") else { return nil }
        let value = String(rest[..<end])
        return value.count == 36 ? value : nil
    }

    private static func isTraced(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return false
        }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: - Window title

    private static func accessibilityTitle(pid: pid_t, cgBounds: CGRect, fallback: String) -> String {
        guard AXIsProcessTrusted(), cgBounds.width > 1, cgBounds.height > 1 else {
            return fallback
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
              let axWindows = windowsRef as? [AXUIElement]
        else {
            return fallback
        }

        let target = ScreenGeometry.cocoaRect(fromCG: cgBounds)
        var bestTitle: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for window in axWindows {
            guard let frame = axFrame(window) else { continue }
            let distance = abs(frame.midX - target.midX)
                + abs(frame.midY - target.midY)
                + abs(frame.width - target.width)
                + abs(frame.height - target.height)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success {
                bestTitle = titleRef as? String
            }
        }

        guard bestDistance < 80, let title = firstNonEmpty(bestTitle) else {
            return fallback
        }
        return title
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef,
              let sizeRef
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func normalizeTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func slug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "unknown" : slug
    }

    private static func firstNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
