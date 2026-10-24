import Darwin
import Foundation

/// Finds the apps behind current sleep assertions so Modafinil can ask them to quit
/// before it puts the Mac to sleep. Pure logic; process and app lookups are injected.
public enum SleepBlockerApps {
    public struct App: Equatable, Hashable {
        public var pid: Int32
        public var bundleID: String
        public var name: String
        public init(pid: Int32, bundleID: String, name: String) {
            self.pid = pid; self.bundleID = bundleID; self.name = name
        }
    }

    /// Never quit: Modafinil, agent and coding tools, terminals, and the Finder.
    public static let protectedBundleIDs: Set<String> = [
        "com.narcotic.modafinil", "com.apple.finder", "com.apple.Terminal", "com.apple.dt.Xcode",
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
        "org.alacritty", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "app.cdxmux.multi"
    ]
    public static let protectedBundlePrefixes = ["com.t3tools.", "com.openai.", "com.anthropic."]
    /// Shown in Settings; matches the identifiers above.
    public static let protectedSummary = "T3 Code, Codex, ChatGPT, Claude, terminals, Xcode, VS Code, Cursor and the Finder"

    public static func isProtected(bundleID: String) -> Bool {
        protectedBundleIDs.contains(bundleID) || protectedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Apps holding (directly, through a helper process, or through a system service
    /// such as coreaudiod) an assertion that stops or delays sleep.
    ///
    /// - Parameters:
    ///   - regularApp: the user-facing app for a PID, or nil for helpers and daemons.
    ///   - parentPID: the parent of a PID, used to map helper processes to their app.
    public static func candidates(
        assertions: [SleepBlockers.Assertion],
        excludedBundleIDs: Set<String>,
        regularApp: (Int32) -> App?,
        parentPID: (Int32) -> Int32? = SleepBlockerApps.parentPID
    ) -> [App] {
        var found: [Int32: App] = [:]
        for assertion in assertions {
            let effect = SleepBlockers.effect(type: assertion.type, name: assertion.name,
                                              processName: assertion.processName)
            guard effect < .background else { continue }
            var pid = assertion.onBehalfOfPID ?? assertion.pid
            var app: App?
            // Helpers (e.g. "Google Chrome Helper") are children of their app.
            for _ in 0..<6 {
                if let match = regularApp(pid) { app = match; break }
                guard let parent = parentPID(pid), parent > 1, parent != pid else { break }
                pid = parent
            }
            guard let app, !isProtected(bundleID: app.bundleID),
                  !excludedBundleIDs.contains(app.bundleID) else { continue }
            found[app.pid] = app
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func parentPID(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
