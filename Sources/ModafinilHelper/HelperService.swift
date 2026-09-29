import Foundation
import ModafinilShared

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: ModafinilConstants.helperMachServiceName)
    private let stateQueue = DispatchQueue(label: "com.narcotic.modafinil.helper.state")
    private let idleExitDelay: TimeInterval = 15
    private var connectedSessionIDs = Set<UUID>()
    private var activeLeaseIDs = Set<UUID>()
    private var idleExitWorkItem: DispatchWorkItem?
    private var sleepTickTimer: DispatchSourceTimer?
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
        })
    }()
    private let wakeScheduler = WakeScheduler()
    private let ownershipMarkerURL = URL(
        fileURLWithPath: "/Library/Application Support/Modafinil/sleep-prevention.enabled"
    )

    override init() {
        super.init()
        listener.delegate = self
        performStartupCleanup()
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
                    reply(true, nil)
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

    fileprivate func sleepAfterDisablingSleepPrevention(
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        stateQueue.async {
            do {
                try self.sleepCoordinator.begin()
                self.updateSleepTickTimer()
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
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
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    private func updateSleepTickTimer() {
        sleepTickTimer?.cancel()
        sleepTickTimer = nil
        guard sleepCoordinator.hasWork else {
            scheduleIdleExitIfNeeded()
            return
        }
        cancelIdleExit()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.sleepCoordinator.tick()
            if !self.sleepCoordinator.hasWork { self.updateSleepTickTimer() }
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
            self.cancelIdleExit()
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

            self.scheduleIdleExitIfNeeded()
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
            self.scheduleIdleExitIfNeeded()
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

    private func scheduleIdleExitIfNeeded() {
        guard connectedSessionIDs.isEmpty, activeLeaseIDs.isEmpty, !sleepCoordinator.hasWork else { return }

        cancelIdleExit()
        let workItem = DispatchWorkItem { [weak self] in
            self?.exitIfStillIdle()
        }
        idleExitWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + idleExitDelay, execute: workItem)
    }

    private func cancelIdleExit() {
        idleExitWorkItem?.cancel()
        idleExitWorkItem = nil
    }

    private func exitIfStillIdle() {
        idleExitWorkItem = nil

        guard connectedSessionIDs.isEmpty, activeLeaseIDs.isEmpty, !sleepCoordinator.hasWork else { return }
        NSLog("ModafinilHelper exiting after idle timeout")
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
