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
/// powerd counts disables per type and forgets them when it restarts, so every disable
/// is paired with exactly one enable through a marker file tied to the boot session.
/// Enabling a type that is not disabled does nothing.
public struct SleepEnforcement {
    public static let assertionTypes = ["PreventSystemSleep", "NetworkClientActive", "BackgroundTask"]
    public static let defaultMarkerURL = URL(
        fileURLWithPath: "/Library/Application Support/Modafinil/sleep-enforcement.json")

    public struct Marker: Codable, Equatable {
        public var bootSession: String
        public var types: [String]
    }

    private let markerURL: URL
    private let bootSession: () -> String?
    /// Runs `pmset <verb> <type>` and throws if powerd refused.
    private let setType: (_ type: String, _ disabled: Bool) throws -> Void
    public private(set) var isEngaged: Bool

    public init(markerURL: URL = SleepEnforcement.defaultMarkerURL,
                bootSession: @escaping () -> String? = ShutdownSchedule.currentBootSession,
                setType: @escaping (_ type: String, _ disabled: Bool) throws -> Void) {
        self.markerURL = markerURL
        self.bootSession = bootSession
        self.setType = setType
        isEngaged = FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Idempotent. Returns a problem worth logging, or nil.
    @discardableResult
    public mutating func set(engaged wanted: Bool) -> String? {
        wanted ? engage() : release()
    }

    private mutating func engage() -> String? {
        guard let session = bootSession() else {
            // Without a boot id a leftover marker could not be told from a live one.
            return "macOS reports no boot session, so sleep blockers stay in effect."
        }
        if let marker = readMarker() {
            if marker.bootSession == session { isEngaged = true; return nil }
            // Left by an earlier boot: powerd has already forgotten those disables.
            try? FileManager.default.removeItem(at: markerURL)
        }
        // The marker goes first: a crash after it only costs harmless extra enables.
        let marker = Marker(bootSession: session, types: Self.assertionTypes)
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            return "The sleep-enforcement marker could not be saved (\(error.localizedDescription)), so sleep blockers stay in effect."
        }
        isEngaged = true
        var failures: [String] = []
        for type in marker.types {
            do { try setType(type, true) } catch { failures.append("\(type): \(error.localizedDescription)") }
        }
        return failures.isEmpty ? nil : "Could not switch off some sleep blockers (\(failures.joined(separator: "; ")))."
    }

    private mutating func release() -> String? {
        guard isEngaged || FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
        var failures: [String] = []
        // After a restart powerd counts no disables, and a marker that cannot be read
        // may still stand for real ones: enabling every type is right in both cases.
        let marker = readMarker()
        let sameBoot = marker == nil || marker?.bootSession == bootSession()
        if sameBoot {
            for type in marker?.types ?? Self.assertionTypes {
                do { try setType(type, false) } catch { failures.append("\(type): \(error.localizedDescription)") }
            }
        }
        guard failures.isEmpty else {
            // Keep the marker so the next call tries again.
            return "Could not switch sleep blockers back on (\(failures.joined(separator: "; "))). Retrying."
        }
        do { try FileManager.default.removeItem(at: markerURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
        catch { return "The sleep-enforcement marker could not be removed (\(error.localizedDescription))." }
        isEngaged = false
        return nil
    }

    private func readMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }
}
