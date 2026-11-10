import AppKit
import Darwin

/// Sunshine, the game-streaming host that Moonlight connects to. While it runs, a Mac
/// cannot stay asleep: an open stream keeps the displays and the system awake, the
/// client's input counts as someone using the Mac, and a Moonlight window that is merely
/// open keeps polling Sunshine's ports, which wakes the Mac again. So Modafinil quits it
/// before a sleep and lets it start again once that sleep is over.
enum StreamingHost {
    static let bundleID = "dev.lizardbyte.app.Sunshine"
    static let name = "Sunshine"

    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isInstalled: Bool { applicationURL != nil }

    static var runningPIDs: [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    /// SIGTERM lets Sunshine end its stream and run its own "undo" commands. Whatever is
    /// left after five seconds is ended. Returns false when it was not running.
    @discardableResult
    static func quit() -> Bool {
        let pids = runningPIDs
        guard !pids.isEmpty else { return false }
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
            for pid in pids where isSunshine(pid) { kill(pid, SIGKILL) }
        }
        return true
    }

    static func open() {
        guard let url = applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The process is still the app that was asked to quit (not a reused PID).
    private static func isSunshine(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).contains("/Sunshine.app/")
    }
}
