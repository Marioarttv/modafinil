import Foundation

@objc(ModafinilHelperProtocol)
public protocol ModafinilHelperProtocol {
    @objc(requestTrackedSleepWithReply:)
    func requestTrackedSleep(withReply reply: @escaping (Bool, String?) -> Void)

    /// Sleep Now at this Mac (0.14.0): like `requestTrackedSleep`, but keyboard or mouse
    /// input in the first seconds does not cancel it, because it is the click itself.
    @objc(requestLocalSleepWithReply:)
    func requestLocalSleep(withReply reply: @escaping (Bool, String?) -> Void)

    /// Asked by a newly started app (0.14.0). True: this helper's executable was replaced
    /// by an update and it is exiting; launchd starts the installed one on the next call.
    @objc(retireIfReplacedWithReply:)
    func retireIfReplaced(withReply reply: @escaping (Bool) -> Void)

    @objc(setSleepTimerAfter:withReply:)
    func setSleepTimer(after seconds: Double, withReply reply: @escaping (Bool, String?) -> Void)

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

    /// Whether the running helper can shut down (it is this version and root), asked
    /// before any app is quit. An older helper fails this call.
    @objc(canShutDownWithReply:)
    func canShutDown(withReply reply: @escaping (Bool, String?) -> Void)

    /// Cancels any sleep timer or pending sleep, then runs `shutdown -h now`. The app
    /// asks the user's apps to quit first; macOS ends whatever is still running.
    @objc(shutDownNowWithReply:)
    func shutDownNow(withReply reply: @escaping (Bool, String?) -> Void)
}
