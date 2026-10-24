import Foundation
import XCTest
@testable import ModafinilShared

final class SleepBlockerAppsTests: XCTestCase {
    private let apps: [Int32: SleepBlockerApps.App] = [
        10: .init(pid: 10, bundleID: "com.google.Chrome", name: "Google Chrome"),
        20: .init(pid: 20, bundleID: "app.legcord.Legcord", name: "Legcord"),
        30: .init(pid: 30, bundleID: "com.t3tools.t3code", name: "T3 Code (Nightly)"),
        40: .init(pid: 40, bundleID: "com.apple.Terminal", name: "Terminal"),
        50: .init(pid: 50, bundleID: "ru.keepcoder.Telegram", name: "Telegram")
    ]
    // Helpers 11 and 12 belong to Chrome; 31 to T3 Code.
    private let parents: [Int32: Int32] = [11: 10, 12: 11, 31: 30, 175: 1]

    private func run(_ assertions: [SleepBlockers.Assertion], excluded: Set<String> = []) -> [String] {
        SleepBlockerApps.candidates(assertions: assertions, excludedBundleIDs: excluded,
                                    regularApp: { self.apps[$0] }, parentPID: { self.parents[$0] }).map(\.name)
    }

    private func assertion(_ pid: Int32, _ type: String, process: String = "x", onBehalf: Int32? = nil) -> SleepBlockers.Assertion {
        .init(pid: pid, processName: process, type: type, name: "n", onBehalfOfPID: onBehalf)
    }

    func testMapsHelpersAndAudioServiceToTheirApp() {
        let found = run([
            assertion(12, "PreventUserIdleSystemSleep"),
            assertion(175, "PreventUserIdleSystemSleep", process: "coreaudiod", onBehalf: 11),
            assertion(20, "PreventSystemSleep")
        ])
        XCTAssertEqual(found, ["Google Chrome", "Legcord"], "One entry per app, sorted")
    }

    func testIncludesDisplayButNotBackgroundOrUserActivity() {
        XCTAssertEqual(run([assertion(50, "PreventUserIdleDisplaySleep")]), ["Telegram"])
        XCTAssertEqual(run([assertion(50, "BackgroundTask"), assertion(50, "UserIsActive")]), [])
    }

    func testNeverQuitsProtectedOrExcludedApps() {
        let assertions = [assertion(31, "PreventSystemSleep"), assertion(40, "PreventUserIdleSystemSleep"),
                          assertion(20, "PreventUserIdleSystemSleep")]
        XCTAssertEqual(run(assertions), ["Legcord"])
        XCTAssertEqual(run(assertions, excluded: ["app.legcord.Legcord"]), [])
        XCTAssertTrue(SleepBlockerApps.isProtected(bundleID: "com.openai.codex"))
        XCTAssertTrue(SleepBlockerApps.isProtected(bundleID: "com.narcotic.modafinil"))
        XCTAssertFalse(SleepBlockerApps.isProtected(bundleID: "com.google.Chrome"))
    }

    func testDaemonsWithoutAnAppAreSkipped() {
        XCTAssertEqual(run([assertion(175, "PreventUserIdleSystemSleep", process: "coreaudiod")]), [])
    }

    func testParentLookupOfCurrentProcess() {
        XCTAssertEqual(SleepBlockerApps.parentPID(getpid()), getppid())
    }
}
