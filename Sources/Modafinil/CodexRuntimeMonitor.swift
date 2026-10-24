import AppKit
import Foundation
import ModafinilShared

final class CodexRuntimeMonitor {
    func isCodexRunning() -> Bool {
        isCodexApplicationRunning() || isCodexCommandRunning()
    }

    private func isCodexApplicationRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            let bundleIdentifier = application.bundleIdentifier?.lowercased()
            let localizedName = application.localizedName?.lowercased()

            return isCodexIdentifier(bundleIdentifier) || isCodexIdentifier(localizedName)
        }
    }

    private func isCodexIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }

        return value == "codex"
            || value.hasPrefix("codex ")
            || value.hasSuffix(" codex")
            || value.contains(".codex")
            || value.contains("codex.")
    }

    /// Same match as `pgrep -ix codex`, without spawning a process every check.
    private func isCodexCommandRunning() -> Bool {
        SleepBlockers.isProcessRunning(named: "codex")
    }
}
