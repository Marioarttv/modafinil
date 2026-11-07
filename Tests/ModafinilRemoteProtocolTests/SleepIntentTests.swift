import Foundation
import XCTest
@testable import ModafinilShared

final class SleepIntentTests: XCTestCase {
    final class Fixture {
        var date = Date(timeIntervalSince1970: 1000)
        var clock = 100.0
        var times = SystemSleepTimes(slept: 900, woke: 950, boot: 1)
        var reason = "enet lan0"
        var idle = 500.0
        var requests = 0
        var saves = 0
        var failSave = false
        var failRequest = false
        var saved = SleepJournal()
        lazy var engine = make()
        func make(journal: SleepJournal = .init()) -> SleepCoordinator {
            SleepCoordinator(journal: journal, now: { self.date }, continuous: { self.clock },
                powerTimes: { self.times }, disablePrevention: {}, requestSleep: {
                    self.requests += 1
                    if self.failRequest { throw SleepError("rejected") }
                }, save: { journal in
                    if self.failSave { throw SleepError("disk failed") }
                    self.saves += 1; self.saved = journal
                }, snapshot: {
                    PowerSnapshot(slept: self.times.slept, woke: self.times.woke, boot: self.times.boot,
                        wakeReason: self.reason, capabilities: 0)
                }, userIdle: { self.idle })
        }
        func advance(_ seconds: Double) { date.addTimeInterval(seconds); clock += seconds; idle += seconds; engine.tick() }
        func sleepAndWake() {
            times.slept = date.timeIntervalSince1970 + 1
            times.woke = times.slept + 10
            advance(11)
        }
        func start() throws { try engine.begin(maintainSleepIntent: true); advance(2) }
    }
    func testNetworkWakeGetsThirtySecondsThenReturnsToSleep() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
        XCTAssertEqual(f.engine.journal.intent?.returnAfter, f.clock + 30)
        f.advance(29); XCTAssertEqual(f.requests, 1)
        f.advance(1); XCTAssertEqual(f.engine.journal.attempt?.trigger, "sleep intent")
        f.advance(2); XCTAssertEqual(f.requests, 2)
    }
    func testAuthenticatedWakeCancelsReturnAndPreservesEvidence() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        try f.engine.cancelPending(); f.advance(60)
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertNotNil(f.engine.journal.attempt?.sleptAt)
        XCTAssertEqual(f.requests, 1)
    }
    func testLocalWakeAndNewPhysicalInputEndIntent() throws {
        for reason in ["HID Activity", "LidOpen"] {
            let f = Fixture(); try f.start(); f.reason = reason; f.sleepAndWake(); f.advance(60)
            XCTAssertNil(f.engine.journal.intent); XCTAssertEqual(f.requests, 1)
        }
        let f = Fixture(); try f.start(); f.sleepAndWake(); f.advance(5)
        f.idle = 0; f.advance(1); f.advance(60)
        XCTAssertNil(f.engine.journal.intent); XCTAssertEqual(f.requests, 1)
    }
    func testDuplicateWakeDoesNotExtendDeadlineAndUnknownWakeIsBounded() throws {
        let f = Fixture(); try f.start(); f.reason = "unknown"; f.sleepAndWake()
        let deadline = f.engine.journal.intent?.returnAfter
        for _ in 0..<29 { f.advance(1) }
        XCTAssertEqual(f.engine.journal.intent?.returnAfter, deadline)
        f.advance(1); f.advance(2); XCTAssertEqual(f.requests, 2)
    }
    func testNaturalResleepCancelsReturnTimerWithoutAnotherPowerRequest() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake()
        f.times.slept = f.date.timeIntervalSince1970 + 1; f.advance(2)
        XCTAssertNil(f.engine.journal.intent?.returnAfter)
        XCTAssertEqual(f.engine.timerMode, .idle)
        XCTAssertEqual(f.requests, 1)
    }
    func testThreeReturnsInTenMinutesStopWakeStorm() throws {
        let f = Fixture(); try f.start()
        for _ in 0..<3 { f.sleepAndWake(); f.advance(30); f.advance(2) }
        f.sleepAndWake(); f.advance(30)
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
        XCTAssertTrue(f.engine.journal.attempt?.detail.contains("three returns") == true)
        let requests = f.requests; f.advance(3600); XCTAssertEqual(f.requests, requests)
    }
    func testSustainedSleepResetsWakeStormBudget() throws {
        let f = Fixture(); try f.start()
        for _ in 0..<3 { f.sleepAndWake(); f.advance(30); f.advance(2) }
        f.times.slept = f.date.timeIntervalSince1970 + 1
        f.times.woke = f.times.slept + 1200; f.advance(1201); f.advance(30); f.advance(2)
        XCTAssertNotNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.intent?.returns.count, 1)
    }
    func testConfirmedIntentAndRemainingGraceSurviveHelperRestart() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake(); f.advance(10)
        let restored = f.make(journal: f.saved); try restored.restore()
        XCTAssertNotNil(restored.journal.intent)
        f.clock += 20; f.date.addTimeInterval(20); restored.tick()
        XCTAssertEqual(restored.journal.attempt?.trigger, "sleep intent")
        XCTAssertEqual(restored.journal.intent?.returns.count, 1)
    }
    func testRebootDoesNotResumeSleepIntent() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake(); f.times.boot = 999
        let restored = f.make(journal: f.saved); try restored.restore()
        XCTAssertNil(restored.journal.intent)
    }
    func testSaveFailureCannotSendReturnSleepAndStopsPolicy() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake(); f.failSave = true
        f.advance(30); f.advance(2)
        XCTAssertNil(f.engine.journal.intent); XCTAssertEqual(f.requests, 1)
    }
    func testNativeRejectionDuringReturnIsReportedAndStopsPolicy() throws {
        let f = Fixture(); try f.start(); f.sleepAndWake(); f.advance(30)
        f.failRequest = true; f.advance(2)
        XCTAssertNil(f.engine.journal.intent)
        XCTAssertEqual(f.engine.journal.attempt?.phase, .failed)
    }
    func testVerificationAllowsDelayedKernelSleepWithoutExtraRetries() throws {
        let f = Fixture(); try f.start(); f.advance(10); f.advance(10); f.advance(60)
        XCTAssertEqual(f.requests, 3); XCTAssertEqual(f.engine.journal.attempt?.phase, .pending)
        f.sleepAndWake()
        XCTAssertEqual(f.engine.journal.attempt?.phase, .confirmed)
    }
    func testSleepIntentDoesNoDiskWorkWhileDormant() throws {
        let f = Fixture(); try f.start()
        f.times.slept = f.date.timeIntervalSince1970 + 1; f.advance(2)
        let saves = f.saves
        f.advance(5); f.advance(5)
        XCTAssertEqual(f.saves, saves)
        XCTAssertEqual(f.engine.timerMode, .verifying) // until first wake evidence is captured
    }
}
