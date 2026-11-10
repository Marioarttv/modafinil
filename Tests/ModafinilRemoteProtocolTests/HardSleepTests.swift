import Foundation
import XCTest
@testable import ModafinilShared

final class SleepEnforcementTests: XCTestCase {
    final class Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modafinil-enforcement-\(UUID().uuidString)/marker.json")
        var boot: String? = "boot-A"
        var calls: [String] = []
        var failing: Set<String> = []
        func make() -> SleepEnforcement {
            SleepEnforcement(markerURL: url, bootSession: { self.boot }, setType: { type, disabled in
                self.calls.append("\(disabled ? "disable" : "enable") \(type)")
                if self.failing.contains(type) { throw SleepError("refused") }
            })
        }
        var markerExists: Bool { FileManager.default.fileExists(atPath: url.path) }
        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func testEveryDisableIsPairedWithOneEnable() {
        let f = Fixture(); var e = f.make()
        XCTAssertFalse(e.isEngaged)
        XCTAssertNil(e.set(engaged: true)); XCTAssertNil(e.set(engaged: true))
        XCTAssertEqual(f.calls, SleepEnforcement.assertionTypes.map { "disable \($0)" })
        XCTAssertTrue(e.isEngaged); XCTAssertTrue(f.markerExists)
        XCTAssertNil(e.set(engaged: false)); XCTAssertNil(e.set(engaged: false))
        XCTAssertEqual(f.calls.suffix(3), SleepEnforcement.assertionTypes.map { "enable \($0)" })
        XCTAssertEqual(f.calls.count, 6)
        XCTAssertFalse(e.isEngaged); XCTAssertFalse(f.markerExists)
    }

    func testRestartedHelperReleasesWhatTheLastOneHeld() {
        let f = Fixture(); var first = f.make(); first.set(engaged: true); f.calls = []
        var second = f.make()
        XCTAssertTrue(second.isEngaged)
        // Still wanted: nothing is disabled a second time.
        XCTAssertNil(second.set(engaged: true)); XCTAssertEqual(f.calls, [])
        XCTAssertNil(second.set(engaged: false))
        XCTAssertEqual(f.calls, SleepEnforcement.assertionTypes.map { "enable \($0)" })
    }

    func testMarkerFromAnotherBootNeedsNoEnableAndDoesNotBlockANewDisable() {
        let f = Fixture(); var first = f.make(); first.set(engaged: true); f.calls = []
        f.boot = "boot-B"
        var afterReboot = f.make()
        XCTAssertNil(afterReboot.set(engaged: false))
        XCTAssertEqual(f.calls, []); XCTAssertFalse(f.markerExists)

        var again = f.make(); again.set(engaged: true); f.calls = []
        f.boot = "boot-C"
        var third = f.make()
        XCTAssertNil(third.set(engaged: true))
        XCTAssertEqual(f.calls, SleepEnforcement.assertionTypes.map { "disable \($0)" })
    }

    func testFailedEnableKeepsTheMarkerAndRetries() {
        let f = Fixture(); var e = f.make(); e.set(engaged: true)
        f.failing = ["NetworkClientActive"]
        XCTAssertNotNil(e.set(engaged: false))
        XCTAssertTrue(e.isEngaged); XCTAssertTrue(f.markerExists)
        f.failing = []
        XCTAssertNil(e.set(engaged: false))
        XCTAssertFalse(e.isEngaged); XCTAssertFalse(f.markerExists)
    }

    func testFailedDisableIsReportedAndStillReleased() {
        let f = Fixture(); var e = f.make()
        f.failing = ["BackgroundTask"]
        XCTAssertNotNil(e.set(engaged: true))
        XCTAssertTrue(e.isEngaged)
        f.failing = []; f.calls = []
        XCTAssertNil(e.set(engaged: false))
        XCTAssertEqual(f.calls.count, 3)
    }

    func testWithoutABootSessionNothingIsDisabled() {
        let f = Fixture(); f.boot = nil; var e = f.make()
        XCTAssertNotNil(e.set(engaged: true))
        XCTAssertEqual(f.calls, []); XCTAssertFalse(e.isEngaged); XCTAssertFalse(f.markerExists)
    }
}

final class HardSleepCoordinatorTests: XCTestCase {
    typealias Fixture = SleepIntentTests.Fixture

    func testEnforcementLastsFromTheRequestUntilTheSleepIsOver() throws {
        let f = Fixture()
        XCTAssertFalse(f.engine.wantsSleepEnforcement)
        try f.engine.begin(maintainSleepIntent: true)
        XCTAssertTrue(f.engine.wantsSleepEnforcement) // before the first native request
        XCTAssertEqual(f.requests, 0)
        f.advance(2); f.sleepAndWake()
        XCTAssertTrue(f.engine.wantsSleepEnforcement) // background wake: still meant to sleep
        try f.engine.cancelPending() // Wake & Keep Awake
        XCTAssertFalse(f.engine.wantsSleepEnforcement)
    }

    func testEnforcementEndsWhenSleepFailsOrSomeoneUsesTheMac() throws {
        let failed = Fixture(); try failed.start()
        failed.advance(130)
        XCTAssertEqual(failed.engine.journal.attempt?.phase, .failed)
        XCTAssertFalse(failed.engine.wantsSleepEnforcement)

        let used = Fixture(); try used.start(); used.reason = "HID Activity"; used.sleepAndWake()
        XCTAssertFalse(used.engine.wantsSleepEnforcement)
    }

    func testInputRightAfterTheRequestIsTheRequestItself() throws {
        let f = Fixture(); try f.engine.begin(maintainSleepIntent: true)
        f.idle = 0; f.advance(1); f.idle = 0; f.advance(2)
        XCTAssertNotNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .pending)
        f.advance(3) // past the grace, idle since
        XCTAssertNotNil(f.engine.journal.intent)
        f.idle = 0; f.advance(1) // someone is using the Mac
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .cancelled)
    }

    func testSleepsAndWakesAreNotedWithoutAnyRequest() {
        let f = Fixture()
        XCTAssertEqual(f.engine.timerMode, .observing)
        f.advance(5)
        XCTAssertNil(f.engine.journal.observedPowerEvents) // the first look only sets the baseline
        f.times.slept = 2000; f.times.woke = 2600; f.reason = "rtc/Maintenance"
        f.advance(5)
        XCTAssertEqual(f.engine.journal.observedPowerEvents?.map(\.kind), [.sleep, .wake])
        XCTAssertEqual(f.engine.journal.observedPowerEvents?.map(\.at), [2000, 2600])
        XCTAssertEqual(f.saved.observedPowerEvents?.count, 2)
        let saves = f.saves
        f.advance(5); f.advance(5)
        XCTAssertEqual(f.saves, saves) // nothing new: no disk writes
        f.times.slept = 2700 // asleep again, seen at the next wake
        f.times.woke = 2900
        f.advance(5)
        XCTAssertEqual(f.engine.journal.observedPowerEvents?.map(\.at), [2000, 2600, 2700, 2900])
    }

    func testOnlyBackgroundWakesOfAnIntendedSleepAreTidiedUp() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        XCTAssertEqual(f.backgroundWakes, 1)
        f.advance(10) // the same wake
        XCTAssertEqual(f.backgroundWakes, 1)
        f.sleepAndWake()
        XCTAssertEqual(f.backgroundWakes, 2)

        let used = Fixture(); try used.start(); used.reason = "HID Activity"; used.sleepAndWake()
        XCTAssertEqual(used.backgroundWakes, 0)
        let noIntent = Fixture(); noIntent.advance(5); noIntent.sleepAndWake()
        XCTAssertEqual(noIntent.backgroundWakes, 0)
    }

    func testObservedEventsAreNotDuplicatedByTheSleepIntent() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        let events = f.engine.journal.observedPowerEvents ?? []
        XCTAssertEqual(events.map(\.kind), [.sleep, .wake])
    }
}

final class HiddenSleepTests: XCTestCase {
    func testNothingIsAddedWhenRecordedSleepExplainsTheClock() {
        let events = [PowerEvent(kind: .sleep, at: 1000), PowerEvent(kind: .wake, at: 4000)]
        XCTAssertNil(HiddenSleep.missingSleep(events: events, since: 900, now: 4005, asleep: 3000))
        XCTAssertNil(HiddenSleep.missingSleep(events: events, since: 900, now: 4005, asleep: 3050))
    }

    func testADayAsleepWithOnlyItsLastSleepRecordedIsNotShownAwake() {
        // Looked at 11:19 (t=0). Asleep from 11:59 with unrecorded background wakes;
        // only the last sleep (21:08–21:26) was recorded.
        let since = 0.0, lastSleep = 35_300.0, wake = 36_400.0
        let events = [PowerEvent(kind: .sleep, at: lastSleep), PowerEvent(kind: .wake, at: wake)]
        let asleep = 32_500.0 // by the clocks
        let event = HiddenSleep.missingSleep(events: events, since: since, now: wake + 1, asleep: asleep)
        XCTAssertEqual(event?.kind, .sleep)
        XCTAssertEqual(event?.at ?? 0, lastSleep - (asleep - (wake - lastSleep)), accuracy: 0.001)
        XCTAssertEqual(event?.reason, HiddenSleep.reason)

        let timeline = PowerTimeline.build(events: [PowerEvent(kind: .appStart, at: -100)] + events + [event!],
                                           from: -100, to: wake + 1)
        let summary = PowerTimeline.summarize(timeline.segments)
        XCTAssertEqual(summary.asleep, asleep, accuracy: 1)
    }

    func testMissingSleepNeverStartsBeforeTheLastLookAndIgnoresOlderEvents() {
        let events = [PowerEvent(kind: .sleep, at: 10), PowerEvent(kind: .wake, at: 20),
                      PowerEvent(kind: .sleep, at: 5000), PowerEvent(kind: .wake, at: 5100)]
        let event = HiddenSleep.missingSleep(events: events, since: 100, now: 5101, asleep: 9000)
        XCTAssertEqual(event?.at, 100)
    }

    func testNoRecordedSleepAtAll() {
        let event = HiddenSleep.missingSleep(events: [], since: 100, now: 1100, asleep: 600)
        XCTAssertEqual(event?.at, 500)
    }

    func testTheSleepClockNeverRunsBackwards() {
        XCTAssertGreaterThanOrEqual(HiddenSleep.asleepTotal(), 0)
    }
}

final class KeepAwakeJobEffectTests: XCTestCase {
    func testOnlySystemSleepJobsHoldAnAutomaticSleep() {
        let assertions = [
            SleepBlockers.Assertion(pid: 10, processName: "caffeinate", type: "PreventSystemSleep", name: "caffeinate"),
            SleepBlockers.Assertion(pid: 11, processName: "caffeinate", type: "PreventUserIdleSystemSleep", name: "caffeinate"),
        ]
        let find = { (effects: Set<SleepBlocker.Effect>) in
            KeepAwakeJobs.find(assertions: assertions, effects: effects, ownPID: 1, isRegularApp: { _ in false },
                               executablePath: { _ in "/usr/bin/caffeinate" }, parentPID: { _ in nil },
                               processName: { _ in "zsh" }).map(\.pid)
        }
        XCTAssertEqual(find([.systemSleep]), [10])
        XCTAssertEqual(find([.systemSleep, .idleSleep]), [10, 11])
    }
}
