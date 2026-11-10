import Foundation

/// Makes a requested sleep really happen on mains power.
///
/// On AC, macOS answers a sleep request with a display-off "DarkWake" that never
/// reaches sleep while certain power assertions are held: a connected File Sharing
/// client (`NetworkClientActive`), `caffeinate -s` or an app (`PreventSystemSleep`),
/// and macOS background tasks with Power Nap on (`BackgroundTask`). On battery macOS
/// ignores all three itself. powerd has a root-only switch that takes an assertion type
/// out of effect system-wide (`pmset disableassertion <type>`); nothing is killed and no
/// service is stopped. Modafinil holds the switch from a sleep request until that sleep
/// is over (a wake the user asked for, or the request failing), then gives it back.
///
/// powerd counts disables per type and forgets them when it restarts; enabling a type
/// that is not disabled does nothing. Modafinil is the only user of the switch, so before
/// every disable it enables the type once: whatever an interrupted run, an earlier helper
/// process or a restarted powerd left behind, the count is then exactly one. A marker
/// file records that types may be disabled, so a restarted helper gives them back.
public struct SleepEnforcement {
    public static let assertionTypes = ["PreventSystemSleep", "NetworkClientActive", "BackgroundTask"]
    public static let defaultMarkerURL = URL(
        fileURLWithPath: "/Library/Application Support/Modafinil/sleep-enforcement.json")

    public struct Marker: Codable, Equatable {
        public var bootSession: String?
        public var types: [String]
    }

    private let markerURL: URL
    private let bootSession: () -> String?
    /// Runs `pmset <verb> <type>` and throws if powerd refused.
    private let setType: (_ type: String, _ disabled: Bool) throws -> Void
    /// Types this process has disabled since the last `reassert()`.
    private var applied: Set<String> = []
    /// A marker exists: some types may be disabled.
    public private(set) var isEngaged: Bool
    public var isFullyApplied: Bool { applied.count == Self.assertionTypes.count }

    public init(markerURL: URL = SleepEnforcement.defaultMarkerURL,
                bootSession: @escaping () -> String? = ShutdownSchedule.currentBootSession,
                setType: @escaping (_ type: String, _ disabled: Bool) throws -> Void) {
        self.markerURL = markerURL
        self.bootSession = bootSession
        self.setType = setType
        isEngaged = FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Idempotent; a failed step is tried again by the next call. Returns a problem
    /// worth logging and reporting, or nil.
    @discardableResult
    public mutating func set(engaged wanted: Bool) -> String? {
        wanted ? engage() : release()
    }

    /// Makes the next `set(engaged: true)` disable every type again. Called for each new
    /// sleep attempt, because a powerd restart silently drops the disables.
    public mutating func reassert() { applied = [] }

    private mutating func engage() -> String? {
        if !isFromThisBoot(readMarker()) || readMarker() == nil {
            // The marker goes first: a crash after it only costs harmless extra enables.
            let marker = Marker(bootSession: bootSession(), types: Self.assertionTypes)
            do {
                try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
            } catch {
                return "The sleep-enforcement marker could not be saved (\(error.localizedDescription)), so sleep blockers stay in effect."
            }
        }
        isEngaged = true
        var failures: [String] = []
        for type in Self.assertionTypes where !applied.contains(type) {
            try? setType(type, false) // back to a count of zero, whatever was left behind
            do { try setType(type, true); applied.insert(type) }
            catch { failures.append("\(type): \(error.localizedDescription)") }
        }
        return failures.isEmpty ? nil : "Could not switch off some sleep blockers (\(failures.joined(separator: "; "))). Retrying."
    }

    private mutating func release() -> String? {
        guard isEngaged || FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        var failures: [String] = []
        // Only a marker that is known to come from another boot needs no enables: powerd
        // has forgotten those disables. An unreadable marker or an unknown boot gets them.
        if isFromThisBoot(readMarker()) {
            for type in Self.assertionTypes {
                do { try setType(type, false); applied.remove(type) }
                catch { failures.append("\(type): \(error.localizedDescription)") }
            }
        }
        guard failures.isEmpty else {
            // Keep the marker so the next call tries again.
            return "Could not switch sleep blockers back on (\(failures.joined(separator: "; "))). Retrying."
        }
        do { try FileManager.default.removeItem(at: markerURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch { return "The sleep-enforcement marker could not be removed (\(error.localizedDescription))." }
        applied = []
        isEngaged = false
        return nil
    }

    /// False only when both boot sessions are known and differ.
    private func isFromThisBoot(_ marker: Marker?) -> Bool {
        guard let saved = marker?.bootSession, let current = bootSession() else { return true }
        return saved == current
    }

    private func readMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }
}
