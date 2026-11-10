import Foundation
import XCTest
@testable import ModafinilShared

final class SleepEnforcementTests: XCTestCase {
    /// A stand-in for powerd: one counter per type that never goes below zero.
    final class Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("modafinil-enforcement-\(UUID().uuidString)/marker.json")
        var boot: String? = "boot-A"
        var counts: [String: Int] = [:]
        var failing: Set<String> = []
        var failEnable = false
        var calls = 0
        func make() -> SleepEnforcement {
            SleepEnforcement(markerURL: url, bootSession: { self.boot }, setType: { type, disabled in
                self.calls += 1
                if disabled {
                    if self.failing.contains(type) { throw SleepError("refused") }
                    self.counts[type, default: 0] += 1
                } else {
                    if self.failEnable { throw SleepError("refused") }
                    self.counts[type] = max(0, self.counts[type, default: 0] - 1)
                }
            })
        }
        var disabled: [String] { SleepEnforcement.assertionTypes.filter { counts[$0, default: 0] > 0 } }
        var maxCount: Int { counts.values.max() ?? 0 }
        var markerExists: Bool { FileManager.default.fileExists(atPath: url.path) }
        func powerdRestarted() { counts = [:] }
        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func testEngageDisablesEachTypeOnceAndReleaseGivesThemBack() {
        let f = Fixture(); var e = f.make()
        XCTAssertFalse(e.isEngaged)
        XCTAssertNil(e.set(engaged: true))
        XCTAssertEqual(f.disabled, SleepEnforcement.assertionTypes)
        XCTAssertTrue(e.isEngaged); XCTAssertTrue(e.isFullyApplied); XCTAssertTrue(f.markerExists)
        let calls = f.calls
        XCTAssertNil(e.set(engaged: true)) // nothing left to do
        XCTAssertEqual(f.calls, calls); XCTAssertEqual(f.maxCount, 1)
        XCTAssertNil(e.set(engaged: false)); XCTAssertNil(e.set(engaged: false))
        XCTAssertEqual(f.disabled, [])
        XCTAssertFalse(e.isEngaged); XCTAssertFalse(f.markerExists)
    }

    func testRestartedHelperNeverLeavesACountAboveOneAndReleasesWhatWasHeld() {
        let f = Fixture(); var first = f.make(); first.set(engaged: true)
        var second = f.make() // the first helper died with the types disabled
        XCTAssertTrue(second.isEngaged); XCTAssertFalse(second.isFullyApplied)
        XCTAssertNil(second.set(engaged: true))
        XCTAssertEqual(f.maxCount, 1); XCTAssertEqual(f.disabled.count, 3)
        var third = f.make()
        XCTAssertNil(third.set(engaged: false))
        XCTAssertEqual(f.disabled, []); XCTAssertFalse(f.markerExists)
    }

    func testCrashBetweenMarkerAndDisablesIsRepaired() throws {
        let f = Fixture()
        // The marker was saved, then the helper died before any disable.
        try FileManager.default.createDirectory(at: f.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SleepEnforcement.Marker(bootSession: "boot-A", types: SleepEnforcement.assertionTypes))
            .write(to: f.url)
        var e = f.make()
        XCTAssertNil(e.set(engaged: true))
        XCTAssertEqual(f.disabled.count, 3); XCTAssertEqual(f.maxCount, 1)
    }

    func testFailedDisableIsRetriedByTheNextCall() {
        let f = Fixture(); var e = f.make()
        f.failing = ["BackgroundTask"]
        XCTAssertNotNil(e.set(engaged: true))
        XCTAssertFalse(e.isFullyApplied); XCTAssertEqual(f.disabled.count, 2)
        f.failing = []
        XCTAssertNil(e.set(engaged: true))
        XCTAssertTrue(e.isFullyApplied); XCTAssertEqual(f.disabled.count, 3); XCTAssertEqual(f.maxCount, 1)
    }

    func testReassertRepairsAPowerdRestartWithoutDoubleCounting() {
        let f = Fixture(); var e = f.make(); e.set(engaged: true)
        f.powerdRestarted()
        XCTAssertNil(e.set(engaged: true)); XCTAssertEqual(f.disabled, []) // not noticed by itself
        e.reassert()
        XCTAssertNil(e.set(engaged: true))
        XCTAssertEqual(f.disabled.count, 3)
        e.reassert(); XCTAssertNil(e.set(engaged: true)) // powerd did not restart this time
        XCTAssertEqual(f.maxCount, 1)
        XCTAssertNil(e.set(engaged: false)); XCTAssertEqual(f.disabled, [])
    }

    func testFailedEnableKeepsTheMarkerReportsItAndRetries() {
        let f = Fixture(); var e = f.make(); e.set(engaged: true)
        f.failEnable = true
        XCTAssertNotNil(e.set(engaged: false))
        XCTAssertTrue(e.isEngaged); XCTAssertTrue(f.markerExists)
        f.failEnable = false
        XCTAssertNil(e.set(engaged: false))
        XCTAssertFalse(e.isEngaged); XCTAssertEqual(f.disabled, [])
    }

    func testMarkerFromAnotherBootNeedsNoEnables() {
        let f = Fixture(); var first = f.make(); first.set(engaged: true)
        f.boot = "boot-B"; f.powerdRestarted(); f.calls = 0
        var afterReboot = f.make()
        XCTAssertNil(afterReboot.set(engaged: false))
        XCTAssertEqual(f.calls, 0); XCTAssertFalse(f.markerExists)
        XCTAssertNil(afterReboot.set(engaged: true)) // and a new sleep works as usual
        XCTAssertEqual(f.disabled.count, 3)
    }

    func testUnknownBootSessionStillGivesTheTypesBack() {
        let f = Fixture(); var e = f.make(); e.set(engaged: true)
        f.boot = nil // macOS stops reporting it
        var later = f.make()
        XCTAssertNil(later.set(engaged: false))
        XCTAssertEqual(f.disabled, []); XCTAssertFalse(f.markerExists)

        let g = Fixture(); g.boot = nil; var h = g.make()
        XCTAssertNil(h.set(engaged: true)); XCTAssertEqual(g.disabled.count, 3)
        XCTAssertNil(h.set(engaged: false)); XCTAssertEqual(g.disabled, [])
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

    func testInputRightAfterSleepNowOnThisMacIsTheClickItself() throws {
        let f = Fixture()
        try f.engine.begin(maintainSleepIntent: true, inputGrace: SleepCoordinator.localInputGrace)
        f.idle = 0; f.advance(1); f.idle = 0; f.advance(2)
        XCTAssertNotNil(f.engine.journal.intent)
        XCTAssertEqual(f.requests, 1)
        f.advance(3) // past the grace, idle since
        XCTAssertNotNil(f.engine.journal.intent)
        f.idle = 0; f.advance(1) // someone is using the Mac
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .cancelled)
    }

    func testAnOldFailedReceiptIsNotRewrittenWhileObserving() throws {
        let f = Fixture(); try f.start(); f.advance(130)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertEqual(f.engine.timerMode, .observing)
        let saves = f.saves
        for _ in 0..<10 { f.advance(5) }
        XCTAssertEqual(f.saves, saves)
    }

    func testAJobStartedDuringABackgroundWakeEndsTheIntentButAnOverriddenOneDoesNot() throws {
        let f = Fixture(); f.jobs = [41] // running when sleep was requested: overridden
        try f.start(); f.sleepAndWake()
        f.advance(20)
        XCTAssertNotNil(f.engine.journal.intent)
        f.jobs = [41, 77] // someone started a render over SSH during the wake
        f.advance(1)
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertFalse(f.engine.wantsSleepEnforcement)
        XCTAssertEqual(f.engine.journal.observedPowerEvents?.last?.kind, .note)
        f.advance(120)
        XCTAssertEqual(f.requests, 1) // never slept over
    }

    func testBackgroundWakeIsTidiedUpOnceAfterTenSeconds() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        XCTAssertEqual(f.backgroundWakes, 1); XCTAssertEqual(f.settled, 0)
        f.advance(9); XCTAssertEqual(f.settled, 0)
        f.advance(1); XCTAssertEqual(f.settled, 1)
        f.advance(30); XCTAssertEqual(f.settled, 1)
        f.sleepAndWake(); f.advance(10)
        XCTAssertEqual(f.backgroundWakes, 2); XCTAssertEqual(f.settled, 2)

        let used = Fixture(); try used.start(); used.reason = "HID Activity"; used.sleepAndWake(); used.advance(15)
        XCTAssertEqual(used.backgroundWakes, 0); XCTAssertEqual(used.settled, 0)
        let noIntent = Fixture(); noIntent.advance(5); noIntent.sleepAndWake(); noIntent.advance(15)
        XCTAssertEqual(noIntent.backgroundWakes, 0); XCTAssertEqual(noIntent.settled, 0)
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

    func testObservedEventsAreNotDuplicatedByTheSleepIntent() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        let events = f.engine.journal.observedPowerEvents ?? []
        XCTAssertEqual(events.map(\.kind), [.sleep, .wake])
    }
}

final class HiddenSleepTests: XCTestCase {
    private func asleep(_ events: [PowerEvent], _ extra: [PowerEvent], from: Double, to: Double) -> Double {
        PowerTimeline.summarize(PowerTimeline.build(
            events: [PowerEvent(kind: .appStart, at: from)] + events + extra, from: from, to: to).segments).asleep
    }

    func testNothingIsAddedWhenRecordedSleepExplainsTheClock() {
        let events = [PowerEvent(kind: .sleep, at: 1000), PowerEvent(kind: .wake, at: 4000)]
        XCTAssertEqual(HiddenSleep.missingSleep(events: events, since: 900, now: 4005, asleep: 3000), [])
        XCTAssertEqual(HiddenSleep.missingSleep(events: events, since: 900, now: 4005, asleep: 3050), [])
    }

    func testADayAsleepWithOnlyItsLastSleepRecordedIsNotShownAwake() {
        // Looked at 11:19 (t=0). Asleep from 11:59 with unrecorded background wakes;
        // only the last sleep (21:08–21:26) was recorded.
        let lastSleep = 35_300.0, wake = 36_400.0
        let events = [PowerEvent(kind: .sleep, at: lastSleep), PowerEvent(kind: .wake, at: wake, dark: false)]
        let total = 32_500.0 // by the clocks
        let added = HiddenSleep.missingSleep(events: events, since: 0, now: wake + 1, asleep: total)
        XCTAssertEqual(added.map(\.at), [lastSleep - (total - (wake - lastSleep))])
        XCTAssertEqual(added.first?.reason, HiddenSleep.reason)
        XCTAssertEqual(asleep(events, added, from: -100, to: wake + 1), total, accuracy: 1)
    }

    func testMissingSleepGoesAfterABackgroundWakeNotIntoTheTimeSomeoneWasWorking() {
        // Working until the first sleep; the helper saw that sleep and its first
        // background wake, missed two short wakes, then saw the last cycle.
        let events = [PowerEvent(kind: .sleep, at: 10_000), PowerEvent(kind: .wake, at: 10_030, dark: true),
                      PowerEvent(kind: .sleep, at: 24_000), PowerEvent(kind: .wake, at: 24_002, dark: false)]
        let total: Double = 13_932
        let added = HiddenSleep.missingSleep(events: events, since: 0, now: 24_003, asleep: total)
        XCTAssertEqual(added.map(\.at), [10_100.0])
        let timeline = PowerTimeline.build(events: [PowerEvent(kind: .appStart, at: 0)] + events + added, from: 0, to: 24_003)
        XCTAssertEqual(timeline.segments.first?.state, .awake)
        XCTAssertEqual(timeline.segments.first?.end, 10_000)
        XCTAssertEqual(PowerTimeline.summarize(timeline.segments).asleep, total, accuracy: 1)
    }

    func testTheMeasuredTotalIsKeptWhenTheMissingSleepLiesBetweenRecordedSleeps() {
        let events = [PowerEvent(kind: .sleep, at: 100), PowerEvent(kind: .wake, at: 200, dark: true),
                      PowerEvent(kind: .sleep, at: 800), PowerEvent(kind: .wake, at: 900, dark: true)]
        let added = HiddenSleep.missingSleep(events: events, since: 0, now: 901, asleep: 500)
        XCTAssertEqual(added.map(\.at), [500])
        XCTAssertEqual(asleep(events, added, from: 0, to: 901), 500, accuracy: 1)
    }

    func testMoreMissingSleepThanOneGapHoldsSpillsIntoTheNext() {
        let events = [PowerEvent(kind: .sleep, at: 1000), PowerEvent(kind: .wake, at: 1100, dark: true),
                      PowerEvent(kind: .sleep, at: 1400), PowerEvent(kind: .wake, at: 1500, dark: false)]
        // 200 recorded, 900 by the clocks: 300 fits after the background wake, 400 before the first sleep.
        let added = HiddenSleep.missingSleep(events: events, since: 0, now: 1501, asleep: 900)
        XCTAssertEqual(Set(added.map(\.at)), Set([1100.0, 600.0]))
        XCTAssertEqual(asleep(events, added, from: 0, to: 1501), 900, accuracy: 1)
    }

    func testAnUnrecordedSleepEndsAtItsRecordedWakeAndNeverAfterTheLastWake() {
        // Only the wake was recorded (the sleep event was lost).
        let events = [PowerEvent(kind: .wake, at: 5000, dark: false)]
        let added = HiddenSleep.missingSleep(events: events, since: 100, now: 5200, asleep: 3000)
        XCTAssertEqual(added.map(\.at), [2000])
        // Nothing recorded at all: there is no place to put it, so nothing is invented.
        XCTAssertEqual(HiddenSleep.missingSleep(events: [], since: 100, now: 1100, asleep: 600), [])
    }

    func testMissingSleepNeverStartsBeforeTheLastLookAndIgnoresOlderEvents() {
        let events = [PowerEvent(kind: .sleep, at: 10), PowerEvent(kind: .wake, at: 20),
                      PowerEvent(kind: .sleep, at: 5000), PowerEvent(kind: .wake, at: 5100)]
        let added = HiddenSleep.missingSleep(events: events, since: 100, now: 5101, asleep: 9000)
        XCTAssertEqual(added.map(\.at), [100])
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
