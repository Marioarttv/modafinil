import Foundation
import ServiceManagement
import ModafinilShared

final class PrivilegedHelperInstaller {
    private let service = SMAppService.daemon(plistName: ModafinilConstants.helperPlistName)

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Opens Modafinil at login so phone control and wake recovery survive restarts.
final class LoginItemController {
    private static let defaultAppliedKey = "LoginItemDefaultApplied"
    private let service = SMAppService.mainApp

    var isEnabled: Bool { service.status == .enabled }

    var statusDescription: String {
        switch service.status {
        case .enabled: return "On"
        case .requiresApproval: return "Needs approval in Login Items"
        case .notRegistered, .notFound: return "Off"
        @unknown default: return "Unknown"
        }
    }

    /// Turns the login item on once, the first time this version runs.
    func applyDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        defaults.set(true, forKey: Self.defaultAppliedKey)
        guard service.status != .enabled else { return }
        do { try service.register() }
        catch { NSLog("Modafinil could not add its login item: \(error.localizedDescription)") }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try service.register() } else { try service.unregister() }
    }
}
