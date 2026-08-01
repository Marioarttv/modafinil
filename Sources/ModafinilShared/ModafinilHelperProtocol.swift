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

    @objc(sleepAfterDisablingSleepPreventionWithReply:)
    func sleepAfterDisablingSleepPrevention(
        withReply reply: @escaping (Bool, String?) -> Void
    )

    @objc(scheduleWakeAtDate:withReply:)
    func scheduleWake(
        at date: Date,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    @objc(cancelScheduledWakeAtDate:withReply:)
    func cancelScheduledWake(
        at date: Date,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}
