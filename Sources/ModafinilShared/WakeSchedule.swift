import Foundation
import IOKit.pwr_mgt

public struct ScheduledPowerEvent: Equatable {
    public let date: Date
    public let owner: String
    public let type: String

    public init(date: Date, owner: String, type: String) {
        self.date = date
        self.owner = owner
        self.type = type
    }
}

/// Owns only Modafinil's one-shot wake event. Other apps' alarms are untouched.
public final class WakeScheduler {
    public static let owner = "com.narcotic.modafinil.scheduled-wake"
    public static let maximumDelay: TimeInterval = 30 * 24 * 60 * 60
    private let events: () -> [ScheduledPowerEvent]
    private let add: (ScheduledPowerEvent) throws -> Void
    private let remove: (ScheduledPowerEvent) throws -> Void

    public init(
        events: @escaping () -> [ScheduledPowerEvent] = WakeScheduler.systemEvents,
        add: @escaping (ScheduledPowerEvent) throws -> Void = WakeScheduler.addSystemEvent,
        remove: @escaping (ScheduledPowerEvent) throws -> Void = WakeScheduler.removeSystemEvent
    ) {
        self.events = events
        self.add = add
        self.remove = remove
    }

    public static func validate(_ date: Date, now: Date = Date()) throws {
        let delay = date.timeIntervalSince(now)
        guard delay.isFinite, delay >= 60, delay <= maximumDelay else {
            throw ScheduleError("Choose a wake time between 1 minute and 30 days from now.")
        }
    }

    public func scheduledDate(now: Date = Date()) -> Date? {
        ownedEvents.filter { $0.date > now }.map(\.date).min()
    }

    public func schedule(_ date: Date, now: Date = Date()) throws {
        try Self.validate(date, now: now)
        let replacement = ScheduledPowerEvent(date: date, owner: Self.owner, type: kIOPMAutoWake)
        // macOS may retain already-fired events whose cancellation returns
        // kIOReturnNotFound. They must not roll back a valid new alarm.
        let previous = ownedEvents.filter { $0.date > now }
        if previous == [replacement] { return }

        // Add before removing, so a failed schedule never loses the old alarm.
        try add(replacement)
        var removed: [ScheduledPowerEvent] = []
        do {
            for event in previous where event != replacement {
                try remove(event)
                removed.append(event)
            }
        } catch {
            let originalError = error
            var rollbackFailed = false
            for event in removed {
                do { try add(event) } catch { rollbackFailed = true }
            }
            do { try remove(replacement) } catch { rollbackFailed = true }
            if rollbackFailed {
                throw ScheduleError("The wake update could not be rolled back completely. Refresh the wake schedule on the Mac before continuing.")
            }
            throw originalError
        }
    }

    public func cancel(now: Date = Date()) throws {
        for event in ownedEvents where event.date > now { try remove(event) }
    }

    private var ownedEvents: [ScheduledPowerEvent] {
        events().filter { $0.owner == Self.owner && $0.type == kIOPMAutoWake }
    }

    public static func systemEvents() -> [ScheduledPowerEvent] {
        guard let list = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard let date = entry[kIOPMPowerEventTimeKey] as? Date,
                  let owner = entry[kIOPMPowerEventAppNameKey] as? String,
                  let type = entry[kIOPMPowerEventTypeKey] as? String else { return nil }
            return ScheduledPowerEvent(date: date, owner: owner, type: type)
        }
    }

    public static func addSystemEvent(_ event: ScheduledPowerEvent) throws {
        let result = IOPMSchedulePowerEvent(event.date as CFDate, event.owner as CFString, event.type as CFString)
        guard result == kIOReturnSuccess else {
            throw ScheduleError("macOS could not schedule the wake event (\(result)).")
        }
    }

    public static func removeSystemEvent(_ event: ScheduledPowerEvent) throws {
        let result = IOPMCancelScheduledPowerEvent(event.date as CFDate, event.owner as CFString, event.type as CFString)
        guard result == kIOReturnSuccess else {
            throw ScheduleError("macOS could not cancel the wake event (\(result)).")
        }
    }

    public struct ScheduleError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
