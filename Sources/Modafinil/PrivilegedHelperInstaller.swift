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
