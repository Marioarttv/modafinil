import Foundation
import SQLite3
import XCTest
@testable import ModafinilT3

final class T3ActivityReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t3-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoRuntimeFileMeansNotRunning() {
        XCTAssertEqual(reader(alive: true).read(), .notRunning)
    }

    func testDeadServerMeansNotRunningEvenWithStaleRuns() throws {
        try writeRuntime(pid: 4242)
        try makeDatabase(runs: [("a", "Stale", "running", nil)])
        XCTAssertEqual(reader(alive: false).read(), .notRunning)
    }

    func testFinishedRunsAreIdle() throws {
        try writeRuntime(pid: 4242)
        try makeDatabase(runs: [("a", "Done", "completed", nil), ("b", "Broke", "failed", nil),
                                ("c", "Stopped", "interrupted", nil), ("d", "Rolled", "rolled_back", nil)])
        XCTAssertEqual(reader(alive: true).read(), .idle)
    }

    func testWorkingAndWaitingThreadsAreBusy() throws {
        try writeRuntime(pid: 4242)
        try makeDatabase(runs: [("a", "Build", "running", nil), ("b", "Ask", "waiting", nil),
                                ("c", "Old", "completed", nil), ("d", "Next", "queued", nil),
                                ("e", "Gone", "running", "2026-10-01T00:00:00Z")])
        guard case .busy(let threads) = reader(alive: true).read() else { return XCTFail("expected busy") }
        XCTAssertEqual(Set(threads.map(\.title)), ["Build", "Ask", "Next"])
        XCTAssertEqual(threads.filter(\.isWaiting).map(\.title), ["Ask"])
        XCTAssertEqual(T3Activity.busy(threads).summary, "T3 threads: 2 working, 1 waiting")
    }

    func testUnexpectedSchemaIsUnavailableAndNeverFinished() throws {
        try writeRuntime(pid: 4242)
        try exec(open(), "CREATE TABLE something_else (id TEXT)")
        let activity = reader(alive: true).read()
        guard case .unavailable = activity else { return XCTFail("expected unavailable, got \(activity)") }
        XCTAssertFalse(activity.isFinished)
    }

    func testMissingDatabaseIsUnavailable() throws {
        try writeRuntime(pid: 4242)
        guard case .unavailable = reader(alive: true).read() else { return XCTFail("expected unavailable") }
    }

    func testCurrentProcessIsNotMistakenForT3() {
        // The test runner is xctest, not a T3 server: a reused PID must not count.
        XCTAssertFalse(T3ActivityReader.isT3ServerProcess(getpid()))
        XCTAssertFalse(T3ActivityReader.isT3ServerProcess(999_999))
    }

    // MARK: Fixture

    private func reader(alive: Bool) -> T3ActivityReader {
        T3ActivityReader(userDataDirectory: directory, isServerProcessAlive: { _ in alive })
    }

    private func writeRuntime(pid: Int32) throws {
        let json = #"{"version":1,"pid":\#(pid),"port":3773}"#
        try json.write(to: directory.appendingPathComponent("server-runtime.json"), atomically: true, encoding: .utf8)
    }

    private func open() throws -> OpaquePointer {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("statev2.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw XCTSkip("sqlite unavailable") }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            XCTFail(message)
        }
    }

    /// Mirrors the columns of T3's tables that the reader depends on, in WAL mode like T3.
    private func makeDatabase(runs: [(thread: String, title: String, status: String, deletedAt: String?)]) throws {
        let db = try open()
        defer { sqlite3_close(db) }
        try exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE orchestration_v2_projection_threads (
              thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT,
              payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_runs (
              run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
              provider TEXT NOT NULL, status TEXT NOT NULL, requested_at TEXT NOT NULL,
              completed_at TEXT, payload_json TEXT NOT NULL);
            """)
        for (index, run) in runs.enumerated() {
            let deleted = run.deletedAt.map { "'\($0)'" } ?? "NULL"
            try exec(db, """
                INSERT INTO orchestration_v2_projection_threads VALUES
                  ('\(run.thread)', 'p', '\(run.title)', 'x', 'x', NULL, \(deleted), '{}');
                INSERT INTO orchestration_v2_projection_runs VALUES
                  ('run-\(run.thread)', '\(run.thread)', 1, 'codex', '\(run.status)', '2026-10-24T10:0\(index):00Z', NULL, '{}');
                """)
        }
    }
}

final class T3SleepWatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let closed = T3SleepWatch.Conditions(isEnabled: true, isKeepAwakeOn: true,
                                                 isLidClosed: true, hasExternalDisplay: false)

    func testSleepsOnlyAfterGracePeriodOfFinishedThreads() {
        var watch = T3SleepWatch(gracePeriod: 60)
        XCTAssertEqual(watch.evaluate(closed, now: start) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(60)))
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(45)) { .notRunning },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(60)))
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(60)) { .idle }, .sleepNow)
    }

    func testNewWorkRestartsTheGracePeriod() {
        var watch = T3SleepWatch(gracePeriod: 60)
        _ = watch.evaluate(closed, now: start) { .idle }
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(30)) {
            .busy([T3ActiveThread(title: "Resume", status: "running")])
        }, .busy)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(70)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(130)))
    }

    func testWaitingThreadAndUnreadableStateKeepTheMacAwake() {
        var watch = T3SleepWatch(gracePeriod: 0)
        XCTAssertEqual(watch.evaluate(closed, now: start) {
            .busy([T3ActiveThread(title: "Approve?", status: "waiting")])
        }, .busy)
        XCTAssertEqual(watch.evaluate(closed, now: start) { .unavailable("schema changed") }, .busy)
    }

    func testDoesNotWatchUnlessLidClosedWithoutExternalDisplayAndKeepAwakeOn() {
        var readCount = 0
        let read: () -> T3Activity = { readCount += 1; return .idle }
        var watch = T3SleepWatch(gracePeriod: 0)
        var conditions = closed
        conditions.isLidClosed = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isLidClosed = nil
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.hasExternalDisplay = true
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isKeepAwakeOn = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        conditions = closed; conditions.isEnabled = false
        XCTAssertEqual(watch.evaluate(conditions, now: start, activity: read), .notWatching)
        XCTAssertEqual(readCount, 0, "T3 is read only while the lid is closed")
    }

    func testOpeningTheLidResetsTheGracePeriod() {
        var watch = T3SleepWatch(gracePeriod: 60)
        _ = watch.evaluate(closed, now: start) { .idle }
        var open = closed
        open.isLidClosed = false
        _ = watch.evaluate(open, now: start.addingTimeInterval(50)) { .idle }
        XCTAssertFalse(watch.isWatching)
        XCTAssertEqual(watch.evaluate(closed, now: start.addingTimeInterval(55)) { .idle },
                       .waitingForGrace(sleepAt: start.addingTimeInterval(115)))
    }
}
