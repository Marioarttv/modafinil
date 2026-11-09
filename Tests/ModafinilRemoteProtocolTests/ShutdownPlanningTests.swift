import Foundation
import XCTest
@testable import ModafinilShared
@testable import ModafinilT3

final class ShutdownPlanningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testScheduleRangeAndStatus() throws {
        XCTAssertThrowsError(try ShutdownSchedule(after: 59, now: now, continuousNow: 100, bootTime: 5))
        XCTAssertThrowsError(try ShutdownSchedule(after: 86_401, now: now, continuousNow: 100, bootTime: 5))
        let schedule = try ShutdownSchedule(after: 600, now: now, continuousNow: 100, bootTime: 5)
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(10), continuousNow: 110, bootTime: 5),
                       .waiting(until: now.addingTimeInterval(600)))
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(600), continuousNow: 700, bootTime: 5), .due)
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(650), continuousNow: 750, bootTime: 5), .due)
    }

    func testSleptThroughTheDeadlineIsMissedNotRun() throws {
        let schedule = try ShutdownSchedule(after: 600, now: now, continuousNow: 100, bootTime: 5)
        // Asleep for an hour: continuous time and the clock both moved on.
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(4200), continuousNow: 4300, bootTime: 5), .missed)
    }

    func testClockSetBackCannotDelayTheTimer() throws {
        let schedule = try ShutdownSchedule(after: 600, now: now, continuousNow: 100, bootTime: 5)
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(-3600), continuousNow: 700, bootTime: 5), .due)
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(-3600), continuousNow: 200, bootTime: 5),
                       .waiting(until: now.addingTimeInterval(-3600 + 500)))
    }

    func testTimerFromAnEarlierBootIsDropped() throws {
        let schedule = try ShutdownSchedule(after: 600, now: now, continuousNow: 100, bootTime: 5)
        XCTAssertEqual(schedule.status(now: now.addingTimeInterval(700), continuousNow: 50, bootTime: 9000), .otherBoot)
    }

    func testKeepAwakeJobsCountCommandLineToolsOnly() {
        typealias A = SleepBlockers.Assertion
        let assertions = [
            A(pid: 3004, processName: "caffeinate", type: "PreventSystemSleep", name: "caffeinate command-line tool", onBehalfOfPID: 3002),
            A(pid: 3004, processName: "caffeinate", type: "PreventUserIdleSystemSleep", name: "caffeinate command-line tool", onBehalfOfPID: 3002),
            A(pid: 50, processName: "ffmpeg", type: "PreventUserIdleSystemSleep", name: "render"),
            A(pid: 51, processName: "coreaudiod", type: "PreventUserIdleSystemSleep", name: "audio", onBehalfOfPID: 70),
            A(pid: 52, processName: "Google Chrome Helper", type: "PreventUserIdleSystemSleep", name: "Video Wake Lock"),
            A(pid: 53, processName: "Safari", type: "PreventUserIdleSystemSleep", name: "Playing"),
            A(pid: 54, processName: "python3", type: "PreventUserIdleDisplaySleep", name: "display only"),
            A(pid: 55, processName: "powerd", type: "PreventUserIdleSystemSleep", name: "Prevent sleep while display is on"),
            A(pid: 99, processName: "Modafinil", type: "PreventSystemSleep", name: "own"),
        ]
        let paths: [Int32: String] = [
            50: "/opt/homebrew/bin/ffmpeg", 51: "/usr/sbin/coreaudiod",
            52: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Google Chrome Helper",
            53: "/Applications/Safari.app/Contents/MacOS/Safari", 54: "/Users/mario/venv/bin/python3",
            55: "/System/Library/CoreServices/powerd.bundle/powerd",
        ]
        let jobs = KeepAwakeJobs.find(assertions: assertions, ownPID: 99, isRegularApp: { $0 == 53 },
                                      executablePath: { paths[$0] }, parentPID: { _ in nil },
                                      processName: { $0 == 3002 ? "zsh" : "?" })
        XCTAssertEqual(jobs, [KeepAwakeJobs.Job(pid: 50, name: "ffmpeg"),
                              KeepAwakeJobs.Job(pid: 3004, name: "caffeinate", forProcess: "zsh, pid 3002")])
        XCTAssertEqual(jobs.last?.title, "caffeinate (for zsh, pid 3002)")
    }

    func testAfterLaunchOnlyANewRunCounts() {
        // Power-on: threads cut off by the shutdown still read as working in T3's database.
        var gate = T3ShutdownGate(armedAt: now)
        gate.note(.busy([T3ActiveThread(title: "Stale", status: "running")]))
        gate.note(.unavailable("locked"))
        XCTAssertFalse(gate.allowsShutdown)
        XCTAssertEqual(gate.decide(keepAwakeJobs: [], isShuttingDown: false), .hold(nil))
        gate.noteLatestRun(requestedAt: now.addingTimeInterval(30))
        XCTAssertTrue(gate.allowsShutdown)
        XCTAssertEqual(gate.decide(keepAwakeJobs: [], isShuttingDown: false), .shutDown)
        XCTAssertEqual(gate.decide(keepAwakeJobs: ["caffeinate (for zsh, pid 3)"], isShuttingDown: false),
                       .hold("waiting for caffeinate (for zsh, pid 3) to finish"))
        XCTAssertEqual(gate.decide(keepAwakeJobs: [], isShuttingDown: true), .hold(nil))
        gate.arm(at: now.addingTimeInterval(60)) // a failed shutdown or a wake
        XCTAssertEqual(gate.decide(keepAwakeJobs: [], isShuttingDown: false), .hold(nil))
    }

    func testARunAlreadyGoingWhenShutdownIsChosenCounts() {
        // Launch, start a render at +10, choose Shut Down at +20 while it runs.
        var gate = T3ShutdownGate(armedAt: now)
        gate.arm(at: now.addingTimeInterval(20))
        gate.noteLatestRun(requestedAt: now.addingTimeInterval(10))
        XCTAssertFalse(gate.allowsShutdown)
        gate.note(.busy([T3ActiveThread(title: "Render", status: "running")]))
        XCTAssertTrue(gate.allowsShutdown)
    }

    func testT3ShutdownNeedsWorkSinceArming() {
        var gate = T3ShutdownGate(armedAt: now, requiresNewRun: false)
        XCTAssertFalse(gate.allowsShutdown)
        gate.noteLatestRun(requestedAt: now.addingTimeInterval(-60)) // a run from before arming
        XCTAssertFalse(gate.allowsShutdown)
        gate.noteLatestRun(requestedAt: nil)
        XCTAssertFalse(gate.allowsShutdown)
        gate.noteLatestRun(requestedAt: now.addingTimeInterval(5))
        XCTAssertTrue(gate.allowsShutdown)
        gate.arm(at: now.addingTimeInterval(100)) // e.g. a remote wake
        XCTAssertFalse(gate.allowsShutdown)
        gate.note(.unavailable("database is locked")) // read errors are not work
        gate.note(.idle)
        gate.note(.notRunning)
        gate.note(.busy([]))
        XCTAssertFalse(gate.allowsShutdown)
        gate.note(.busy([T3ActiveThread(title: "Render", status: "running")]))
        XCTAssertTrue(gate.allowsShutdown)
    }
}
