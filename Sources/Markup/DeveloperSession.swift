import AppKit
import Darwin
import Security

enum ScreenCaptureAccess: Equatable {
    case granted
    case denied
    case needsRelaunch
    case blockedByDebugger
}

enum DeveloperSession {
    static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return false
        }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isAdHocSigned: Bool {
        signingTeamIdentifier == nil
    }

    static var signingTeamIdentifier: String? {
        let url = isPackagedApp ? Bundle.main.bundleURL : Bundle.main.executableURL
        guard let url else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information = information as? [String: Any]
        else {
            return nil
        }

        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return team
        }

        return nil
    }

    static var tccStabilityWarning: String? {
        if isDebuggerAttached {
            return "Xcode's debugger is attached. macOS will not give Markup a working Screen Recording permission until it is relaunched without the debugger. Use the Markup scheme, not Markup Debug."
        }
        if !isPackagedApp {
            return "This process is not Markup.app. Open Markup.xcodeproj and Run the Markup scheme, or launch a signed build from ./scripts/build-app.sh, so macOS can remember Screen Recording permission."
        }
        if isAdHocSigned {
            return "This build is ad-hoc signed, so macOS treats every rebuild as a new app. In Xcode, select your Apple Development team under Signing & Capabilities."
        }
        return nil
    }

    static func logLaunchWarnings() {
        if let warning = tccStabilityWarning {
            NSLog("Markup: \(warning)")
        }
    }

    static func relaunchDetached() {
        if isPackagedApp {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("Markup: failed to relaunch packaged app: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            NSApp.terminate(nil)
            return
        }

        do {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = Array(CommandLine.arguments.dropFirst())
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
        } catch {
            NSLog("Markup: failed to relaunch: \(error.localizedDescription)")
        }

        NSApp.terminate(nil)
    }
}
