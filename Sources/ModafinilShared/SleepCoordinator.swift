import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt

public struct SleepAttempt: Codable, Equatable {
    public enum Phase: String, Codable { case pending, confirmed, failed, cancelled }
    public var id: String
    public var requestedAt: Date
    public var baselineSleep: TimeInterval
    public var deadline: TimeInterval
    public var nextAttempt: TimeInterval
    public var attempts: Int
    public var phase: Phase
    public var sleptAt: Date?
    public var wokeAt: Date?
    public var detail: String
}

public struct SleepSchedule: Codable, Equatable {
    public var date: Date
    public var continuousDeadline: TimeInterval
    public var bootTime: TimeInterval
}

public struct SleepJournal: Codable, Equatable {
    public var schedule: SleepSchedule?
    public var attempt: SleepAttempt?
    public init() {}
}

public struct SystemSleepTimes {
    public var slept: TimeInterval
    public var woke: TimeInterval
    public var boot: TimeInterval
    public init(slept: TimeInterval, woke: TimeInterval, boot: TimeInterval) {
        self.slept = slept; self.woke = woke; self.boot = boot
    }
    public static func read() throws -> Self {
        func readTime(_ key: String) throws -> TimeInterval {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
                throw SleepError("Cannot read macOS sleep history (\(key)).")
            }
            return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return try Self(slept: readTime("kern.sleeptime"), woke: readTime("kern.waketime"), boot: readTime("kern.boottime"))
    }
    public static var continuousTime: TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

public struct SleepError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Requests sleep through the documented API; acceptance is not proof of sleep.
public enum NativeSleep {
    public static func request() throws {
        let connection = IOPMFindPowerManagement(0)
        guard connection != 0 else { throw SleepError("Cannot connect to macOS power management.") }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else {
            throw SleepError(String(format: "macOS rejected sleep (IOKit 0x%08x).", result))
        }
    }
}

public enum SleepJournalStore {
    public static let url = URL(fileURLWithPath: "/Library/Application Support/Modafinil/sleep-journal.json")
    public static func read() throws -> SleepJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return SleepJournal() }
        return try JSONDecoder().decode(SleepJournal.self, from: Data(contentsOf: url))
    }
    public static func write(_ journal: SleepJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}

/// Called only on the helper's serial queue. No power requests occur in init.
/// Injected dependencies allow verification without putting the test host to sleep.
public final class SleepCoordinator {
    public private(set) var journal: SleepJournal
    private let now: () -> Date
    private let continuous: () -> TimeInterval
    private let powerTimes: () throws -> SystemSleepTimes
    private let disablePrevention: () throws -> Void
    private let requestSleep: () throws -> Void
    private let save: (SleepJournal) throws -> Void
    public var hasWork: Bool { journal.schedule != nil || journal.attempt?.phase == .pending }

    public init(journal: SleepJournal = .init(), now: @escaping () -> Date = Date.init,
                continuous: @escaping () -> TimeInterval = { SystemSleepTimes.continuousTime },
                powerTimes: @escaping () throws -> SystemSleepTimes = SystemSleepTimes.read,
                disablePrevention: @escaping () throws -> Void,
                requestSleep: @escaping () throws -> Void = NativeSleep.request,
                save: @escaping (SleepJournal) throws -> Void = SleepJournalStore.write) {
        self.journal = journal; self.now = now; self.continuous = continuous
        self.powerTimes = powerTimes; self.disablePrevention = disablePrevention
        self.requestSleep = requestSleep; self.save = save
    }

    public func restore() throws {
        // Never resume a half-completed operation after a helper crash.
        if let attempt = journal.attempt, attempt.phase == .pending {
            let times = try powerTimes()
            if times.slept > attempt.baselineSleep {
                journal.attempt?.phase = .confirmed
                journal.attempt?.sleptAt = Date(timeIntervalSince1970: times.slept)
                journal.attempt?.detail = "macOS recorded a system sleep before the helper restarted."
            } else {
                journal.attempt?.phase = .failed
                journal.attempt?.detail = "The helper restarted before sleep was verified. Request sleep again."
            }
        }
        if let schedule = journal.schedule, schedule.bootTime != (try powerTimes()).boot {
            journal.schedule = nil
        }
        try persist()
        tick()
    }

    public func stopAfterFailure(_ detail: String) {
        journal.schedule = nil
        journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: now(), baselineSleep: 0,
            deadline: continuous(), nextAttempt: continuous(), attempts: 0, phase: .failed, detail: detail)
        try? persist()
    }

    public func schedule(after seconds: TimeInterval) throws {
        guard seconds.isFinite, (60...86400).contains(seconds) else {
            throw SleepError("The sleep timer must be between 1 minute and 24 hours.")
        }
        let prior = journal
        journal.schedule = SleepSchedule(date: now().addingTimeInterval(seconds),
            continuousDeadline: continuous() + seconds, bootTime: try powerTimes().boot)
        do { try persist() } catch { journal = prior; throw error }
    }

    public func cancelSchedule() throws {
        let prior = journal
        journal.schedule = nil
        do { try persist() } catch { journal = prior; throw error }
    }

    public func cancelPending() throws {
        guard journal.attempt?.phase == .pending else { return }
        if let attempt = journal.attempt, let times = try? powerTimes(), times.slept > attempt.baselineSleep {
            journal.attempt?.phase = .confirmed
            journal.attempt?.sleptAt = Date(timeIntervalSince1970: times.slept)
            journal.attempt?.wokeAt = times.woke >= times.slept ? Date(timeIntervalSince1970: times.woke) : nil
            journal.attempt?.detail = "Sleep was recorded before the newer power command."
        } else {
            journal.attempt?.phase = .cancelled
            journal.attempt?.detail = "Sleep request cancelled by a newer power command."
        }
        try persist()
    }

    public func begin() throws {
        let times = try powerTimes()
        try disablePrevention()
        let time = continuous()
        journal.schedule = nil
        journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: now(), baselineSleep: times.slept,
            deadline: time + 32, nextAttempt: time + 2, attempts: 0, phase: .pending,
            detail: "Sleep requested. Waiting for macOS to enter sleep.")
        do { try persist() } // Durable receipt before acknowledging or issuing a power request.
        catch {
            journal.attempt?.phase = .failed
            journal.attempt?.detail = "The sleep receipt could not be saved. No power request was sent."
            throw error
        }
    }

    public func tick() {
        do {
            let time = continuous()
            let times = try powerTimes()
            if let schedule = journal.schedule, now() >= schedule.date || time >= schedule.continuousDeadline {
                // Never put a just-awakened Mac back to sleep for an elapsed timer.
                if times.slept > 0, times.slept <= schedule.date.timeIntervalSince1970,
                   times.woke >= schedule.date.timeIntervalSince1970 {
                    journal.schedule = nil
                    journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                        baselineSleep: times.slept, deadline: time, nextAttempt: time, attempts: 0,
                        phase: .confirmed, sleptAt: Date(timeIntervalSince1970: times.slept),
                        wokeAt: Date(timeIntervalSince1970: times.woke),
                        detail: "The Mac was already asleep when the timer elapsed; it has since woken.")
                    try persist()
                } else if time - schedule.continuousDeadline > 60 || now().timeIntervalSince(schedule.date) > 60 {
                    journal.schedule = nil
                    journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                        baselineSleep: times.slept, deadline: time, nextAttempt: time, attempts: 0,
                        phase: .failed, detail: "The sleep timer was missed by more than a minute. Request sleep again.")
                    try persist()
                } else { try begin() }
            }
            guard var attempt = journal.attempt else { return }
            if attempt.phase == .pending {
                if times.slept > attempt.baselineSleep {
                    attempt.phase = .confirmed
                    attempt.sleptAt = Date(timeIntervalSince1970: times.slept)
                    attempt.detail = "macOS recorded a system sleep."
                } else if abs(now().timeIntervalSince(attempt.requestedAt) - (time - (attempt.deadline - 32))) > 5 {
                    attempt.phase = .failed
                    attempt.detail = "The system clock changed during sleep verification. No further retries will run."
                } else if time >= attempt.deadline {
                    attempt.phase = .failed
                    attempt.detail = "macOS did not enter sleep within 30 seconds of the first attempt. No further retries will run. Background activity or macOS may be delaying sleep."
                } else if time >= attempt.nextAttempt, attempt.attempts < 3 {
                    attempt.attempts += 1
                    attempt.nextAttempt = time + 10
                    journal.attempt = attempt
                    try persist()
                    try requestSleep()
                    return
                }
            }
            if let sleptAt = attempt.sleptAt, times.woke >= sleptAt.timeIntervalSince1970 {
                attempt.wokeAt = Date(timeIntervalSince1970: times.woke)
                attempt.detail = "Sleep was confirmed; macOS subsequently woke (background or full wake)."
            }
            if journal.attempt != attempt { journal.attempt = attempt; try persist() }
        } catch {
            if let schedule = journal.schedule {
                journal.schedule = nil
                journal.attempt = SleepAttempt(id: UUID().uuidString, requestedAt: schedule.date,
                    baselineSleep: 0, deadline: continuous(), nextAttempt: continuous(), attempts: 0,
                    phase: .failed, detail: error.localizedDescription)
                try? persist()
            }
            if journal.attempt?.phase == .pending {
                journal.attempt?.phase = .failed
                journal.attempt?.detail = error.localizedDescription
                try? persist()
            }
            NSLog("Modafinil sleep coordinator: %@", error.localizedDescription)
        }
    }

    private func persist() throws {
        try save(journal)
    }
}
