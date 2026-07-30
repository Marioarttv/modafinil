import Foundation
import Security
import ModafinilShared

enum ClientValidator {
    private static let appRequirement: SecRequirement? = {
        guard let teamIdentifier = helperTeamIdentifier() else {
            NSLog("ModafinilHelper could not determine its own signing team")
            return nil
        }

        let requirementText = """
        anchor apple generic and identifier "\(ModafinilConstants.appBundleIdentifier)" and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        )

        if status != errSecSuccess {
            NSLog("ModafinilHelper could not create client signing requirement: \(status)")
            return nil
        }

        return requirement
    }()

    private static func helperTeamIdentifier() -> String? {
        var helperCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &helperCode) == errSecSuccess,
              let helperCode
        else {
            return nil
        }

        var helperStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            helperCode,
            SecCSFlags(),
            &helperStaticCode
        ) == errSecSuccess,
            let helperStaticCode
        else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            helperStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
            let information = signingInformation as? [CFString: Any],
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
            !teamIdentifier.isEmpty
        else {
            return nil
        }

        return teamIdentifier
    }

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
