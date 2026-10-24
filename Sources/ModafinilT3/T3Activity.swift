import Darwin
import Foundation
import SQLite3

/// A T3 Code thread whose latest run has not finished.
public struct T3ActiveThread: Equatable {
    public var title: String
    /// T3's run status: preparing, queued, starting, running or waiting.
    public var status: String

    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }

    /// "waiting" means T3 needs an answer or approval; everything else is work in progress.
    public var isWaiting: Bool { status == "waiting" }
}

public enum T3Activity: Equatable {
    /// The T3 Code server is not running, so no thread can be working.
    case notRunning
    /// The server is running and every thread has finished.
    case idle
    case busy([T3ActiveThread])
    /// T3's state could not be read. Treated as busy so the Mac never sleeps on a guess.
    case unavailable(String)

    public var summary: String {
        switch self {
        case .notRunning: return "T3 Code is not running"
        case .idle: return "No T3 threads working or waiting"
        case .busy(let threads):
            let waiting = threads.filter(\.isWaiting).count
            let working = threads.count - waiting
            var parts: [String] = []
            if working > 0 { parts.append("\(working) working") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            return "T3 threads: " + parts.joined(separator: ", ")
        case .unavailable(let reason): return "Cannot read T3 Code: \(reason)"
        }
    }

    public var isFinished: Bool {
        switch self {
        case .notRunning, .idle: return true
        case .busy, .unavailable: return false
        }
    }
}

/// Reads T3 Code's thread state from its local database, read-only.
///
/// T3 stores each thread's runs in `orchestration_v2_projection_runs`; a thread is
/// active while its run is in one of T3's own active statuses. One indexed query
/// takes a few milliseconds, so it is cheap enough to poll while the lid is closed.
public struct T3ActivityReader {
    /// T3's `activeRunStatuses`: a thread in one of these is working or waiting.
    public static let activeRunStatuses = ["preparing", "queued", "starting", "running", "waiting"]

    public var userDataDirectory: URL
    /// Whether the process recorded in `server-runtime.json` is a live T3 server.
    public var isServerProcessAlive: (Int32) -> Bool

    public init(
        userDataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata", isDirectory: true),
        isServerProcessAlive: @escaping (Int32) -> Bool = T3ActivityReader.isT3ServerProcess
    ) {
        self.userDataDirectory = userDataDirectory
        self.isServerProcessAlive = isServerProcessAlive
    }

    public func read() -> T3Activity {
        guard let pid = serverPID(), isServerProcessAlive(pid) else { return .notRunning }
        let databaseURL = userDataDirectory.appendingPathComponent("statev2.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .unavailable("its state database is missing")
        }
        do {
            let threads = try Self.activeThreads(databasePath: databaseURL.path)
            return threads.isEmpty ? .idle : .busy(threads)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func serverPID() -> Int32? {
        let url = userDataDirectory.appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    static func activeThreads(databasePath: String) throws -> [T3ActiveThread] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open the database"
            sqlite3_close(db)
            throw ReadError(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let statuses = activeRunStatuses.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
            SELECT COALESCE(t.title, 'Untitled thread'), r.status
            FROM orchestration_v2_projection_runs r
            LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = r.thread_id
            WHERE r.status IN (\(statuses)) AND t.deleted_at IS NULL
            GROUP BY r.thread_id
            ORDER BY r.requested_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var threads: [T3ActiveThread] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError(String(cString: sqlite3_errmsg(db))) }
            let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "Untitled thread"
            let status = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "running"
            threads.append(T3ActiveThread(title: title, status: status))
        }
        return threads
    }

    /// True for a live process whose executable looks like a T3 Code server
    /// (the desktop app, or the CLI run with node or bun). Guards against a
    /// stale `server-runtime.json` whose PID was reused by another process.
    public static func isT3ServerProcess(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        let name = (path as NSString).lastPathComponent.lowercased()
        return path.contains("T3 Code") || name == "node" || name == "bun" || name.hasPrefix("t3")
    }

    struct ReadError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Decides when a closed-lid Mac may go to sleep because T3 Code has finished.
public struct T3SleepWatch {
    public struct Conditions: Equatable {
        public var isEnabled: Bool
        /// Keep-awake was asked for and is in effect (not just a wake-recovery lease).
        public var isKeepAwakeOn: Bool
        public var isLidClosed: Bool?
        public var hasExternalDisplay: Bool

        public init(isEnabled: Bool, isKeepAwakeOn: Bool, isLidClosed: Bool?, hasExternalDisplay: Bool) {
            self.isEnabled = isEnabled
            self.isKeepAwakeOn = isKeepAwakeOn
            self.isLidClosed = isLidClosed
            self.hasExternalDisplay = hasExternalDisplay
        }

        /// Only a closed lid without an external display: a Mac used in clamshell
        /// mode with a monitor must never be put to sleep.
        public var isWatching: Bool {
            isEnabled && isKeepAwakeOn && isLidClosed == true && !hasExternalDisplay
        }
    }

    public enum Decision: Equatable {
        case notWatching
        case busy
        case waitingForGrace(sleepAt: Date)
        case sleepNow
    }

    /// How long T3 must stay finished before sleeping. Covers the short gap
    /// between a delegated task finishing and its parent thread resuming, and
    /// a queued message starting the next turn.
    public static let defaultGracePeriod: TimeInterval = 60

    public let gracePeriod: TimeInterval
    public private(set) var finishedSince: Date?

    public init(gracePeriod: TimeInterval = T3SleepWatch.defaultGracePeriod) {
        self.gracePeriod = gracePeriod
    }

    public var isWatching: Bool { finishedSince != nil }

    /// Call once per check. `activity` is read only when the conditions allow sleeping.
    public mutating func evaluate(
        _ conditions: Conditions,
        now: Date,
        activity: () -> T3Activity
    ) -> Decision {
        guard conditions.isWatching else {
            finishedSince = nil
            return .notWatching
        }
        guard activity().isFinished else {
            finishedSince = nil
            return .busy
        }
        let since = finishedSince ?? now
        finishedSince = since
        let sleepAt = since.addingTimeInterval(gracePeriod)
        return now >= sleepAt ? .sleepNow : .waitingForGrace(sleepAt: sleepAt)
    }

    public mutating func reset() {
        finishedSince = nil
    }
}
