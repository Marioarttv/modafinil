import Foundation
import IOKit.pwr_mgt
import ModafinilShared

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: ModafinilConstants.helperMachServiceName)
    private let stateQueue = DispatchQueue(label: "com.narcotic.modafinil.helper.state")
    private var connectedSessionIDs = Set<UUID>()
    private var activeLeaseIDs = Set<UUID>()
    private var sleepTickTimer: DispatchSourceTimer?
    private var sleepTimerMode: SleepCoordinator.TimerMode = .observing
    private var sleepEnforcement = SleepEnforcement(setType: { type, disabled in
        // pmset reports a refusal on standard output and still exits 0.
        let output = try Shell.run("/usr/bin/pmset", [disabled ? "disableassertion" : "enableassertion", type])
        if !output.isEmpty { throw SleepError(output) }
    })
    private var lastEnforcementProblem: String?
    private var lastEnforcementTry: TimeInterval = 0
    private var enforcedAttemptID: String?
    /// Notes sleeps and wakes for Sleep History; runs for as long as the helper does.
    private var observeTimer: DispatchSourceTimer?
    private var wakeHoldAssertion: IOPMAssertionID = 0
    /// The helper binary this process was started from (device, inode, change time).
    private let startedFrom = HelperService.executableIdentity()
    private var sleepJournalLoadError: String?
    private lazy var sleepCoordinator: SleepCoordinator = {
        let journal: SleepJournal
        do { journal = try SleepJournalStore.read() }
        catch {
            sleepJournalLoadError = "Saved sleep state could not be read. Set the timer again."
            journal = SleepJournal()
        }
        return SleepCoordinator(journal: journal, disablePrevention: { [unowned self] in
            try self.setSystemSleepPreventionEnabled(false)
            self.activeLeaseIDs.removeAll()
            self.removeOwnershipMarker()
        }, failureHint: { SleepBlockers.failureHint() }, keepAwakeJobs: {
            // Command-line jobs only (`caffeinate -s`, a render tool): apps and macOS
            // services such as a Power Nap backup are not someone asking to stay awake.
            Set(KeepAwakeJobs.find(assertions: SleepBlockers.readAssertions(), effects: [.systemSleep],
                                   isRegularApp: { _ in false }).map(\.pid))
        }, backgroundWakeBegan: { [unowned self] in self.holdBackgroundWake() },
           backgroundWakeSettled: { [unowned self] in self.endFileSharingDaemon() })
    }()
    private let wakeScheduler = WakeScheduler()
    private lazy var powerMonitor = SystemPowerMonitor(callbackQueue: stateQueue)
    private let ownershipMarkerURL = URL(
        fileURLWithPath: "/Library/Application Support/Modafinil/sleep-prevention.enabled"
    )

    override init() {
        super.init()
        listener.delegate = self
        performStartupCleanup()
        powerMonitor.onDidWake = { [weak self] in
            guard let self else { return }
            self.sleepCoordinator.tick()
            self.updateSleepTickTimer()
        }
        do { try powerMonitor.start() } catch { NSLog("ModafinilHelper power monitoring failed: %@", error.localizedDescription) }
        // A wall-clock timer would fire late after the clock is set back; re-arm it.
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.sleepTickTimer?.cancel()
                self.sleepTickTimer = nil
                self.sleepTimerMode = .observing
                self.updateSleepTickTimer()
            }
        }
    }

    func run() {
        listener.resume()
        RunLoop.current.run()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard ClientValidator.allows(processIdentifier: newConnection.processIdentifier) else {
            return false
        }

        let session = HelperSession(service: self)
        clientConnectionStarted(sessionID: session.id)

        newConnection.exportedInterface = NSXPCInterface(with: ModafinilHelperProtocol.self)
        newConnection.exportedObject = session
        newConnection.invalidationHandler = { [weak self] in
            self?.clientConnectionEnded(sessionID: session.id)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.clientConnectionEnded(sessionID: session.id)
        }
        newConnection.resume()
        return true
    }

    fileprivate func setSleepPreventionEnabled(
        _ enabled: Bool,
        sessionID: UUID,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                try self.sleepCoordinator.cancelPending()
                self.updateSleepTickTimer()
                if enabled {
                    do {
                        try self.writeOwnershipMarker()
                        try self.setSystemSleepPreventionEnabled(true)
                        self.activeLeaseIDs.insert(sessionID)
                        reply(true, nil)
                    } catch {
                        self.removeOwnershipMarker()
                        reply(false, error.localizedDescription)
                    }
                } else {
                    try self.setSystemSleepPreventionEnabled(false)
                    self.activeLeaseIDs.removeAll()
                    self.removeOwnershipMarker()
                    if let failure = self.enforcementReleaseFailure() { reply(false, failure) }
                    else { reply(true, nil) }
                }
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    fileprivate func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                let enabled = try self.readSleepPreventionStatus()
                reply(true, enabled, nil)
            } catch {
                reply(false, false, error.localizedDescription)
            }
        }
    }

    /// - Parameter local: Sleep Now at this Mac: input in the next seconds is the click.
    fileprivate func sleepAfterDisablingSleepPrevention(
        local: Bool = false,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                try self.sleepCoordinator.begin(trigger: "request", maintainSleepIntent: true,
                    inputGrace: local ? SleepCoordinator.localInputGrace : 0)
                self.updateSleepTickTimer()
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    fileprivate func canShutDown(withReply reply: @escaping (Bool, String?) -> Void) {
        guard geteuid() == 0 else { reply(false, "The helper is not running as root."); return }
        guard FileManager.default.isExecutableFile(atPath: "/sbin/shutdown") else {
            reply(false, "/sbin/shutdown is missing."); return
        }
        reply(true, nil)
    }

    fileprivate func shutDownNow(withReply reply: @escaping (Bool, String?) -> Void) {
        stateQueue.async {
            // A sleep request racing the shutdown would leave a sleeping, not an off, Mac.
            try? self.sleepCoordinator.cancelSchedule()
            try? self.sleepCoordinator.cancelPending()
            self.updateSleepTickTimer()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
            process.arguments = ["-h", "now", "Modafinil: shutdown requested"]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch {
                reply(false, "macOS did not start the shutdown: \(error.localizedDescription)")
                return
            }
            // `shutdown` may never return once launchd starts stopping processes.
            guard exited.wait(timeout: .now() + 3) == .success else {
                NSLog("ModafinilHelper shutdown in progress")
                reply(true, nil)
                return
            }
            guard process.terminationStatus == 0 else {
                let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                reply(false, "macOS refused the shutdown (status \(process.terminationStatus))\(text.isEmpty ? "" : ": " + String(text.prefix(200))).")
                return
            }
            NSLog("ModafinilHelper started a shutdown")
            reply(true, nil)
        }
    }

    fileprivate func setSleepTimer(after seconds: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        stateQueue.async {
            do {
                if seconds == -1 {
                    try self.sleepCoordinator.cancelSchedule()
                    try self.sleepCoordinator.cancelPending()
                } else if seconds == 0 { try self.sleepCoordinator.cancelSchedule() }
                else { try self.sleepCoordinator.schedule(after: seconds) }
                self.updateSleepTickTimer()
                if seconds == -1, let failure = self.enforcementReleaseFailure() { reply(false, failure) }
                else { reply(true, nil) }
            } catch { reply(false, error.localizedDescription) }
        }
    }

    /// Holds powerd's assertion switch exactly while the coordinator wants it. Called
    /// after every state change and tick, so it is engaged before the first native
    /// sleep request (two seconds after a request) and released with the sleep intent.
    private func reconcileSleepEnforcement() {
        let wanted = sleepCoordinator.wantsSleepEnforcement
        if wanted, let attempt = sleepCoordinator.journal.attempt, attempt.phase == .pending,
           attempt.id != enforcedAttemptID {
            // Every sleep attempt disables the types afresh: powerd may have restarted.
            enforcedAttemptID = attempt.id
            sleepEnforcement.reassert()
        }
        let settled = wanted ? (sleepEnforcement.isEngaged && sleepEnforcement.isFullyApplied)
                             : !sleepEnforcement.isEngaged
        guard !settled else { lastEnforcementProblem = nil; return }
        // A step that keeps failing is retried every five seconds, not every tick.
        let time = SystemSleepTimes.continuousTime
        guard lastEnforcementProblem == nil || time - lastEnforcementTry >= 5 else { return }
        lastEnforcementTry = time
        let problem = sleepEnforcement.set(engaged: wanted)
        if let problem, problem != lastEnforcementProblem {
            NSLog("ModafinilHelper sleep enforcement: %@", problem)
        }
        lastEnforcementProblem = problem
    }

    /// Sleep blockers that could not be switched back on, for the caller of a command
    /// that ends a sleep: quitting or uninstalling must not leave them off unnoticed.
    private func enforcementReleaseFailure() -> String? {
        guard !sleepCoordinator.wantsSleepEnforcement, sleepEnforcement.isEngaged else { return nil }
        return lastEnforcementProblem ?? "Sleep blockers could not be switched back on."
    }

    /// After a background wake of an intended sleep, macOS goes back to sleep by itself
    /// about 25 seconds later now that nothing holds it. A phone that asked for the wake
    /// needs time to reach this Mac (Wi-Fi, Tailscale) and authenticate, so the wake is
    /// held open for 45 seconds, about what the blockers used to give it by accident.
    private func holdBackgroundWake() {
        if wakeHoldAssertion != 0 { IOPMAssertionRelease(wakeHoldAssertion); wakeHoldAssertion = 0 }
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: "InternalPreventSleep", // powerd's own dark-wake linger type
            kIOPMAssertionNameKey: "Modafinil: time for Wake & Keep Awake to arrive",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: 45,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        var id = IOPMAssertionID(0)
        if IOPMAssertionCreateWithProperties(properties as CFDictionary, &id) == kIOReturnSuccess {
            wakeHoldAssertion = id
        }
    }

    /// Runs when a background wake of an intended sleep is about to end with the Mac
    /// going back to sleep (no Wake & Keep Awake arrived in 40 seconds). File Sharing's
    /// smbd is ended; launchd starts a new one for the next connection. Two reasons, both
    /// seen on the Mac mini (macOS 27.2):
    /// - a running smbd never answers the sleep notification, so every return to sleep
    ///   waits out its 28-second timeout;
    /// - a client that is still connected (the other Mac's unmount came five minutes
    ///   late) woke the Mac again ten seconds after every sleep. Its session cannot
    ///   outlive the sleep anyway, so ending it loses nothing the sleep would not.
    private func endFileSharingDaemon() {
        _ = try? Shell.run("/usr/bin/killall", ["-TERM", "smbd"])
    }

    /// Sleeps and wakes are noted every five seconds for as long as the helper runs
    /// (a dispatch timer never wakes the Mac). On top of that the mode timer ticks once
    /// per second during sleep verification or a background-wake grace period, and once
    /// at the sleep timer's date (wall clock, so it also fires right after a wake if the
    /// date passed during sleep).
    private func updateSleepTickTimer() {
        reconcileSleepEnforcement()
        if observeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.sleepCoordinator.tick()
                self.updateSleepTickTimer()
                self.exitIfReplaced()
            }
            observeTimer = timer
            timer.resume()
        }
        let mode = sleepCoordinator.timerMode
        if mode == sleepTimerMode { return }
        sleepTickTimer?.cancel()
        sleepTickTimer = nil
        sleepTimerMode = mode
        let timer: DispatchSourceTimer
        switch mode {
        case .monitoring, .observing:
            return // the observe timer is enough
        case .verifying:
            timer = DispatchSource.makeTimerSource(queue: stateQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        case .deadline(let scheduledDate):
            timer = DispatchSource.makeTimerSource(queue: stateQueue)
            let date = sleepCoordinator.timerDeadline(now: Date(), continuousNow: SystemSleepTimes.continuousTime)
                ?? scheduledDate
            let seconds = date.timeIntervalSince1970
            let wall = DispatchWallTime(timespec: timespec(
                tv_sec: Int(seconds.rounded(.down)),
                tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000)))
            // The repeat only matters if the wall clock moved backwards.
            timer.schedule(wallDeadline: wall, repeating: 30, leeway: .milliseconds(500))
        }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sleepCoordinator.tick()
            self.updateSleepTickTimer()
        }
        sleepTickTimer = timer
        timer.resume()
    }

    fileprivate func setScheduledWake(_ timestamp: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        stateQueue.async {
            do {
                if timestamp == 0 {
                    try self.wakeScheduler.cancel()
                } else {
                    try self.wakeScheduler.schedule(Date(timeIntervalSince1970: timestamp))
                }
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    private func clientConnectionStarted(sessionID: UUID) {
        stateQueue.async {
            self.connectedSessionIDs.insert(sessionID)
        }
    }

    private func clientConnectionEnded(sessionID: UUID) {
        stateQueue.async {
            self.connectedSessionIDs.remove(sessionID)
            let hadActiveLease = self.activeLeaseIDs.remove(sessionID) != nil

            if hadActiveLease, self.activeLeaseIDs.isEmpty {
                do {
                    try self.setSystemSleepPreventionEnabled(false)
                    self.removeOwnershipMarker()
                    NSLog("ModafinilHelper restored normal sleep behavior after client disconnect")
                } catch {
                    NSLog("ModafinilHelper could not restore sleep after client disconnect: \(error.localizedDescription)")
                }
            }
            self.exitIfReplaced()
        }
    }

    private func performStartupCleanup() {
        stateQueue.async {
            self.restoreStaleSleepPreventionIfNeeded()
            do {
                let coordinator = self.sleepCoordinator
                if let error = self.sleepJournalLoadError { coordinator.stopAfterFailure(error) }
                else { try coordinator.restore() }
            } catch {
                self.sleepCoordinator.stopAfterFailure("Sleep monitoring could not restart: \(error.localizedDescription)")
            }
            self.updateSleepTickTimer()
        }
    }

    private func restoreStaleSleepPreventionIfNeeded() {
        guard FileManager.default.fileExists(atPath: ownershipMarkerURL.path) else {
            return
        }

        do {
            try setSystemSleepPreventionEnabled(false)
            activeLeaseIDs.removeAll()
            removeOwnershipMarker()
            NSLog("ModafinilHelper restored stale sleep-prevention state on startup")
        } catch {
            NSLog("ModafinilHelper could not restore stale sleep-prevention state: \(error.localizedDescription)")
        }
    }

    private static func executableIdentity() -> String? {
        guard let path = Bundle.main.executablePath else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        // Not the change time: an extended-attribute write would look like a new binary.
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }

    private var isReplaced: Bool { Self.executableIdentity() != startedFrom }

    /// A newly started app asks this first. A helper whose executable was replaced by
    /// an update answers true and exits, so launchd starts the installed one for the
    /// app's next request; sleep blockers are given back before it goes.
    fileprivate func retireIfReplaced(withReply reply: @escaping (Bool) -> Void) {
        stateQueue.async {
            guard self.isReplaced, self.activeLeaseIDs.isEmpty, !self.sleepCoordinator.hasWork else {
                reply(false)
                return
            }
            _ = self.sleepEnforcement.set(engaged: false)
            NSLog("ModafinilHelper exiting for a newly installed app: its executable was replaced")
            reply(true)
            self.stateQueue.asyncAfter(deadline: .now() + 0.2) { exit(EXIT_SUCCESS) }
        }
    }

    /// The helper stays running to note sleeps and wakes, so after an app update it
    /// makes room for the new binary itself: once the app is gone and nothing is
    /// pending, a replaced (or removed) executable ends this process. launchd starts
    /// the installed helper for the next request.
    private func exitIfReplaced() {
        guard connectedSessionIDs.isEmpty, activeLeaseIDs.isEmpty, !sleepCoordinator.hasWork,
              !sleepEnforcement.isEngaged, isReplaced else { return }
        NSLog("ModafinilHelper exiting: its executable was replaced")
        exit(EXIT_SUCCESS)
    }

    private func setSystemSleepPreventionEnabled(_ enabled: Bool) throws {
        try Shell.run("/usr/bin/pmset", ["-a", "disablesleep", enabled ? "1" : "0"])
    }

    private func readSleepPreventionStatus() throws -> Bool {
        let output = try Shell.run("/usr/bin/pmset", ["-g"])
        return output
            .split(separator: "\n")
            .first { $0.contains("SleepDisabled") }?
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .last == "1"
    }

    private func writeOwnershipMarker() throws {
        let directoryURL = ownershipMarkerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: ownershipMarkerURL, options: .atomic)
    }

    private func removeOwnershipMarker() {
        do {
            try FileManager.default.removeItem(at: ownershipMarkerURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            NSLog("ModafinilHelper could not remove sleep-prevention ownership marker: \(error.localizedDescription)")
        }
    }
}

private final class HelperSession: NSObject, ModafinilHelperProtocol {
    let id = UUID()
    private weak var service: HelperService?

    init(service: HelperService) {
        self.service = service
    }

    func requestTrackedSleep(withReply reply: @escaping (Bool, String?) -> Void) {
        sleepAfterDisablingSleepPrevention(withReply: reply)
    }

    func requestLocalSleep(withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else { reply(false, "The helper service is unavailable."); return }
        service.sleepAfterDisablingSleepPrevention(local: true, withReply: reply)
    }

    func retireIfReplaced(withReply reply: @escaping (Bool) -> Void) {
        guard let service else { reply(false); return }
        service.retireIfReplaced(withReply: reply)
    }

    func canShutDown(withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else { reply(false, "The helper service is unavailable."); return }
        service.canShutDown(withReply: reply)
    }

    func shutDownNow(withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else { reply(false, "The helper service is unavailable."); return }
        service.shutDownNow(withReply: reply)
    }

    func setSleepTimer(after seconds: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else { reply(false, "The helper service is unavailable."); return }
        service.setSleepTimer(after: seconds, withReply: reply)
    }

    func setScheduledWake(_ timestamp: Double, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let service else {
            reply(false, "The helper service is unavailable.")
            return
        }
        service.setScheduledWake(timestamp, withReply: reply)
    }

    func setSleepPreventionEnabled(
        _ enabled: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard let service else {
            reply(false, "The helper service is unavailable.")
            return
        }

        service.setSleepPreventionEnabled(enabled, sessionID: id, withReply: reply)
    }

    func getSleepPreventionStatus(
        withReply reply: @escaping (Bool, Bool, String?) -> Void
    ) {
        guard let service else {
            reply(false, false, "The helper service is unavailable.")
            return
        }

        service.getSleepPreventionStatus(withReply: reply)
    }

    func sleepAfterDisablingSleepPrevention(
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard let service else {
            reply(false, "The helper service is unavailable.")
            return
        }

        service.sleepAfterDisablingSleepPrevention(withReply: reply)
    }
}
