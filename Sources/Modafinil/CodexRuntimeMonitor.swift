import AppKit
import Foundation

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

    private func isCodexCommandRunning() -> Bool {
        do {
            _ = try Shell.run("/usr/bin/pgrep", ["-ix", "codex"])
            return true
        } catch {
            return false
        }
    }
}
