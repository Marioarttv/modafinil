import Foundation

@objc(ModafinilHelperProtocol)
public protocol ModafinilHelperProtocol {
    @objc(setScheduledWake:withReply:)
    func setScheduledWake(
        _ timestamp: Double,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    @objc(setSleepPreventionEnabled:withReply:)
    func setSleepPreventionEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    @objc(getSleepPreventionStatusWithReply:)
    func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    )

    @objc(sleepAfterDisablingSleepPreventionWithReply:)
    func sleepAfterDisablingSleepPrevention(
        withReply reply: @escaping (Bool, String?) -> Void
    )
}
