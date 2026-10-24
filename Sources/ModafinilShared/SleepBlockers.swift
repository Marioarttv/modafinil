import Foundation
import Darwin
import IOKit.pwr_mgt

/// An app or system process currently holding a power assertion.
public struct SleepBlocker: Codable, Equatable {
    public enum Effect: String, Codable, Comparable {
        // Ordered from strongest to weakest.
        case systemSleep, idleSleep, display, background, userActive

        public var title: String {
            switch self {
            case .systemSleep: return "Prevents system sleep"
            case .idleSleep: return "Prevents idle sleep"
            case .display: return "Keeps the display on"
            case .background: return "macOS background work"
            case .userActive: return "You are using the Mac"
            }
        }

        private var rank: Int {
            switch self {
            case .systemSleep: return 0
            case .idleSleep: return 1
            case .display: return 2
            case .background: return 3
            case .userActive: return 4
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    public var processName: String
    public var pid: Int32
    public var effect: Effect
    /// Assertion names supplied by the app, e.g. "Video Wake Lock".
    public var details: [String]

    public init(processName: String, pid: Int32, effect: Effect, details: [String]) {
        self.processName = processName; self.pid = pid; self.effect = effect; self.details = details
    }
}

public enum SleepBlockers {
    public struct Assertion: Equatable {
        public var pid: Int32
        public var processName: String
        public var type: String
        public var name: String
        /// Set when a system service holds the assertion for an app, e.g. coreaudiod
        /// playing Chrome's audio ("Created for PID" in `pmset -g assertions`).
        public var onBehalfOfPID: Int32?
        public init(pid: Int32, processName: String, type: String, name: String, onBehalfOfPID: Int32? = nil) {
            self.pid = pid; self.processName = processName; self.type = type; self.name = name
            self.onBehalfOfPID = onBehalfOfPID
        }
    }

    /// Reads current assertions once. Unprivileged and cheap; never call it on a timer.
    public static func current() -> [SleepBlocker] {
        summarize(readAssertions())
    }

    public static func readAssertions() -> [Assertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [Assertion] = []
        for (pidNumber, assertions) in byProcess {
            let pid = pidNumber.int32Value
            for assertion in assertions {
                if let level = assertion["AssertLevel"] as? NSNumber, level.intValue == 0 { continue }
                let type = assertion["AssertType"] as? String ?? ""
                let name = assertion["AssertName"] as? String ?? ""
                let processName = (assertion["Process Name"] as? String) ?? processName(for: pid)
                let onBehalf = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                result.append(Assertion(pid: pid, processName: processName, type: type, name: name,
                                        onBehalfOfPID: onBehalf.flatMap { $0 > 0 && $0 != pid ? $0 : nil }))
            }
        }
        return result
    }

    public static func effect(type: String, name: String, processName: String) -> SleepBlocker.Effect {
        let process = processName.lowercased()
        if type == "UserIsActive" { return .userActive }
        // powerd holds this whenever the display is on; it reflects your own use.
        if process == "powerd", name.lowercased().contains("display is on") { return .userActive }
        switch type {
        case "PreventSystemSleep", "DenySystemSleep": return .systemSleep
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": return .idleSleep
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return .display
        default: return .background
        }
    }

    /// Groups assertions by process, keeping each process's strongest effect.
    public static func summarize(_ assertions: [Assertion]) -> [SleepBlocker] {
        var grouped: [Int32: SleepBlocker] = [:]
        for assertion in assertions {
            let effect = effect(type: assertion.type, name: assertion.name, processName: assertion.processName)
            var blocker = grouped[assertion.pid] ?? SleepBlocker(
                processName: assertion.processName, pid: assertion.pid, effect: effect, details: [])
            blocker.effect = min(blocker.effect, effect)
            if !assertion.name.isEmpty, !blocker.details.contains(assertion.name), blocker.details.count < 3 {
                blocker.details.append(assertion.name)
            }
            grouped[assertion.pid] = blocker
        }
        return grouped.values.sorted {
            $0.effect == $1.effect ? $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
                : $0.effect < $1.effect
        }
    }

    /// One sentence naming apps that held sleep-related assertions, for failure receipts.
    public static func failureHint(_ blockers: [SleepBlocker] = current()) -> String? {
        let relevant = blockers.filter { $0.effect < .background }
        guard !relevant.isEmpty else { return nil }
        let list = relevant.prefix(4).map { "\($0.processName) (\($0.effect.title.lowercased()))" }
            .joined(separator: ", ")
        return "Apps holding sleep assertions then: \(list)."
    }

    public static func processName(for pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    /// Exact, case-insensitive process-name match without spawning `pgrep`.
    public static func isProcessRunning(named target: String) -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return false }
        let lowered = target.lowercased()
        var buffer = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0,
               String(cString: buffer).lowercased() == lowered {
                return true
            }
        }
        return false
    }
}
