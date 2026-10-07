import Foundation
import XCTest
import ModafinilShared

final class WakeSchedulerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Backend {
        var events: [ScheduledPowerEvent] = []
        var failAdd = false
        var failRemove: ScheduledPowerEvent?
        var scheduler: WakeScheduler {
            WakeScheduler(events: { self.events }, add: { event in
                if self.failAdd { throw WakeScheduler.ScheduleError("add failed") }
                self.events.append(event)
            }, remove: { event in
                if self.failRemove == event { throw WakeScheduler.ScheduleError("remove failed") }
                self.events.removeAll { $0 == event }
            })
        }
    }

    private func event(_ delay: TimeInterval, owner: String = WakeScheduler.owner, type: String = "wake") -> ScheduledPowerEvent {
        ScheduledPowerEvent(date: now.addingTimeInterval(delay), owner: owner, type: type)
    }

    func testReplaceAndCancelPreserveOtherAppsAndOtherEventTypes() throws {
        let backend = Backend()
        let unrelated = [event(500, owner: "other.app"), event(600, type: "sleep")]
        backend.events = unrelated + [event(120)]
        try backend.scheduler.schedule(now.addingTimeInterval(900), now: now)
        XCTAssertEqual(backend.events, unrelated + [event(900)])
        try backend.scheduler.cancel()
        XCTAssertEqual(backend.events, unrelated)
    }

    func testUncancellableExpiredRecordDoesNotBlockNewWakeOrCancellation() throws {
        let backend = Backend()
        let expired = event(-60)
        let unrelated = event(500, owner: "other.app")
        backend.events = [expired, unrelated, event(120)]
        backend.failRemove = expired
        try backend.scheduler.schedule(now.addingTimeInterval(900), now: now)
        XCTAssertEqual(backend.events, [expired, unrelated, event(900)])
        XCTAssertEqual(backend.scheduler.scheduledDate(now: now), event(900).date)
        try backend.scheduler.cancel(now: now)
        XCTAssertEqual(backend.events, [expired, unrelated])
        XCTAssertNil(backend.scheduler.scheduledDate(now: now))
    }

    func testInvalidDatesNeverChangeTheQueue() {
        let backend = Backend()
        backend.events = [event(600)]
        for delay in [-1.0, 0, 59, WakeScheduler.maximumDelay + 1, .infinity, .nan] {
            XCTAssertThrowsError(try backend.scheduler.schedule(now.addingTimeInterval(delay), now: now))
            XCTAssertEqual(backend.events, [event(600)])
        }
    }

    func testValidDateBoundsAndIdempotence() throws {
        let backend = Backend()
        try backend.scheduler.schedule(now.addingTimeInterval(60), now: now)
        try backend.scheduler.schedule(now.addingTimeInterval(60), now: now)
        XCTAssertEqual(backend.events, [event(60)])
        try backend.scheduler.schedule(now.addingTimeInterval(WakeScheduler.maximumDelay), now: now)
        XCTAssertEqual(backend.events, [event(WakeScheduler.maximumDelay)])
    }

    func testFailedAddPreservesExistingAlarm() {
        let backend = Backend()
        backend.events = [event(600)]
        backend.failAdd = true
        XCTAssertThrowsError(try backend.scheduler.schedule(now.addingTimeInterval(900), now: now))
        XCTAssertEqual(backend.events, [event(600)])
    }

    func testFailedReplacementRestoresPreviouslyRemovedAlarm() {
        let backend = Backend()
        backend.events = [event(600), event(700)]
        backend.failRemove = event(700)
        XCTAssertThrowsError(try backend.scheduler.schedule(now.addingTimeInterval(900), now: now))
        XCTAssertEqual(Set(backend.events.map(\.date)), Set([event(600).date, event(700).date]))
        XCTAssertEqual(backend.events.count, 2)
    }

    func testReadOnlyListsFutureOwnedWakeEvents() {
        let backend = Backend()
        backend.events = [event(-10), event(60, owner: "other.app"), event(70, type: "sleep"), event(700), event(600)]
        XCTAssertEqual(backend.scheduler.scheduledDate(now: now), now.addingTimeInterval(600))
    }
}
