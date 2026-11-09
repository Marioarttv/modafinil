import Darwin
import Foundation

/// A one-time "shut down at" timer (protocol v8). The app owns it, because a clean
/// shutdown first asks the user's apps to quit. It belongs to one boot, and like the
/// sleep timer it never fires late: a Mac that slept through the time stays on.
public struct ShutdownSchedule: Codable, Equatable {
    public var date: Date
    public var continuousDeadline: TimeInterval
    public var bootTime: TimeInterval
    /// kern.bootsessionuuid: unique per boot, unlike kern.boottime, which moves with
    /// clock steps and can be close for two quick boots.
    public var bootSession: String?

    public static let allowedSeconds: ClosedRange<TimeInterval> = 60...86_400
    /// Later than this after the deadline (for example after a sleep) counts as missed.
    public static let missedTolerance: TimeInterval = 60

    public enum Status: Equatable {
        case waiting(until: Date)
        case due
        case missed
        /// Saved before the last restart or shutdown.
        case otherBoot
    }

    public init(date: Date, continuousDeadline: TimeInterval, bootTime: TimeInterval, bootSession: String? = nil) {
        self.date = date; self.continuousDeadline = continuousDeadline; self.bootTime = bootTime
        self.bootSession = bootSession
    }

    public init(after seconds: TimeInterval, now: Date, continuousNow: TimeInterval, bootTime: TimeInterval,
                bootSession: String? = nil) throws {
        guard seconds.isFinite, Self.allowedSeconds.contains(seconds) else {
            throw SleepError("The shutdown timer must be between 1 minute and 24 hours.")
        }
        self.init(date: now.addingTimeInterval(seconds), continuousDeadline: continuousNow + seconds,
                  bootTime: bootTime, bootSession: bootSession)
    }

    /// This boot's identifier, or nil if macOS does not report one.
    public static func currentBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    /// Fires on continuous time only, so moving the clock either way cannot change when
    /// it fires; `date` is for display. Continuous time includes sleep, so a deadline
    /// passed while asleep is missed, and so is one that fell inside the last sleep even
    /// if the Mac woke within the tolerance: a just-woken Mac is never shut down for it.
    /// - Parameter lastSleep: kern.sleeptime and kern.waketime, if known.
    public func status(now: Date, continuousNow: TimeInterval, bootTime: TimeInterval,
                       bootSession: String? = nil,
                       lastSleep: (slept: TimeInterval, woke: TimeInterval)? = nil) -> Status {
        if let saved = self.bootSession {
            // Exact: a timer never survives a restart or power cut.
            guard saved == bootSession else { return .otherBoot }
        } else {
            // Without a session id, kern.boottime (moves with clock steps) within 60 s.
            guard bootSession == nil, abs(bootTime - self.bootTime) < 60 else { return .otherBoot }
        }
        // Continuous time restarts at each boot: a deadline beyond this boot's uptime
        // can only be from another boot.
        guard continuousDeadline - continuousNow <= Self.allowedSeconds.upperBound else { return .otherBoot }
        let remaining = continuousDeadline - continuousNow
        if remaining > 0 { return .waiting(until: now.addingTimeInterval(remaining)) }
        if let sleep = lastSleep, sleep.slept > 0, sleep.woke >= sleep.slept {
            let deadline = now.addingTimeInterval(remaining).timeIntervalSince1970
            if sleep.slept <= deadline, deadline <= sleep.woke { return .missed }
        }
        return -remaining > Self.missedTolerance ? .missed : .due
    }
}

/// Command-line jobs that keep the Mac awake on purpose, such as `caffeinate` around a
/// render or an `ffmpeg` export. An automatic shutdown waits for them; sleep does not,
/// because sleep only pauses them. Apps and macOS services are listed elsewhere as
/// sleep blockers and do not count here.
public enum KeepAwakeJobs {
    public struct Job: Equatable {
        public var pid: Int32
        public var name: String
        /// The process the job keeps awake for, e.g. the script that started `caffeinate -w`.
        public var forProcess: String?
        public init(pid: Int32, name: String, forProcess: String? = nil) {
            self.pid = pid; self.name = name; self.forProcess = forProcess
        }
        public var title: String { forProcess.map { "\(name) (for \($0))" } ?? name }
    }

    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Applications/"]

    /// - Parameters:
    ///   - isRegularApp: true for a user-facing app (those quit before shutdown).
    ///   - executablePath: the process's executable, or nil when unknown.
    public static func find(
        assertions: [SleepBlockers.Assertion],
        ownPID: Int32 = getpid(),
        isRegularApp: (Int32) -> Bool,
        executablePath: (Int32) -> String? = KeepAwakeJobs.executablePath,
        parentPID: (Int32) -> Int32? = SleepBlockerApps.parentPID,
        processName: (Int32) -> String = SleepBlockers.processName
    ) -> [Job] {
        var jobs: [Int32: Job] = [:]
        for assertion in assertions where assertion.pid != ownPID && jobs[assertion.pid] == nil {
            let effect = SleepBlockers.effect(type: assertion.type, name: assertion.name,
                                              processName: assertion.processName)
            guard effect == .systemSleep || effect == .idleSleep else { continue }
            let isCaffeinate = assertion.processName == "caffeinate"
            if !isCaffeinate {
                guard !isRegularApp(assertion.pid), let path = executablePath(assertion.pid),
                      !path.contains(".app/"),
                      path.hasPrefix("/usr/local/") || !systemPrefixes.contains(where: { path.hasPrefix($0) })
                else { continue }
            }
            var owner: String?
            if isCaffeinate, let other = assertion.onBehalfOfPID ?? parentPID(assertion.pid), other > 1 {
                owner = "\(processName(other)), pid \(other)"
            }
            jobs[assertion.pid] = Job(pid: assertion.pid, name: assertion.processName, forProcess: owner)
        }
        return jobs.values.sorted { $0.pid < $1.pid }
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
}
