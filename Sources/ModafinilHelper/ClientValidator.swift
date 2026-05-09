import Foundation
import Security
import ModafinilShared

enum ClientValidator {
    private static let appRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            ModafinilConstants.appSigningRequirement as CFString,
            SecCSFlags(),
            &requirement
        )

        if status != errSecSuccess {
            NSLog("ModafinilHelper could not create client signing requirement: \(status)")
            return nil
        }

        return requirement
    }()

    static func allows(processIdentifier pid: pid_t) -> Bool {
        var guest: SecCode?
        let attributes: [String: Any] = [
            kSecGuestAttributePid as String: pid
        ]

        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            SecCSFlags(),
            &guest
        )
        guard guestStatus == errSecSuccess, let guest else {
            NSLog("ModafinilHelper rejected pid \(pid): could not inspect code signature")
            return false
        }

        guard let appRequirement else {
            NSLog("ModafinilHelper rejected pid \(pid): missing client signing requirement")
            return false
        }

        let validityStatus = SecCodeCheckValidity(guest, SecCSFlags(), appRequirement)
        guard validityStatus == errSecSuccess else {
            NSLog("ModafinilHelper rejected pid \(pid): signing requirement failed with status \(validityStatus)")
            return false
        }

        return true
    }
}
