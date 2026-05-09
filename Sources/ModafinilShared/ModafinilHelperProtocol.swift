import Foundation

@objc(ModafinilHelperProtocol)
public protocol ModafinilHelperProtocol {
    @objc(setSleepPreventionEnabled:withReply:)
    func setSleepPreventionEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    @objc(getSleepPreventionStatusWithReply:)
    func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    )
}
