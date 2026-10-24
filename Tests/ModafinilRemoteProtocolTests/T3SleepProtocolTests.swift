import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

/// Protocol v6. Mirrored in the companion repository; both protocol copies must stay identical.
final class T3SleepProtocolTests: XCTestCase {
    private let secret = Data(repeating: 9, count: 32)

    func testSetT3SleepRequiresVersionSix() throws {
        let verifier = RemoteRequestVerifier(secret: secret)
        let old = RemoteRequest.signed(version: 5, command: .setT3Sleep, argument: "1", secret: secret)
        XCTAssertThrowsError(try verifier.verify(old))
        let current = RemoteRequest.signed(version: 6, command: .setT3Sleep, argument: "1", secret: secret)
        XCTAssertNoThrow(try verifier.verify(current))
        XCTAssertEqual(RemoteT3Sleep.parseArgument("1"), true)
        XCTAssertEqual(RemoteT3Sleep.parseArgument("0"), false)
        XCTAssertNil(RemoteT3Sleep.parseArgument("yes"))
    }

    func testOlderClientsNeverReceiveT3State() {
        let t3 = RemoteT3Sleep(enabled: true, summary: "T3 threads: 1 working", working: 1, sleepAt: 1_000)
        let state = RemoteState(awakeRequested: true, sleepPreventionEffective: true, serverName: "Mac",
                                blockers: [], t3Sleep: t3)
        let v5 = RemoteResponse.signed(version: 5, requestID: "a", ok: true, state: state, message: "ok", secret: secret)
        XCTAssertNil(v5.state?.t3Sleep)
        XCTAssertTrue(v5.isAuthentic(secret: secret))
        let v6 = RemoteResponse.signed(version: 6, requestID: "a", ok: true, state: state, message: "ok", secret: secret)
        XCTAssertEqual(v6.state?.t3Sleep, t3)
        XCTAssertTrue(v6.isAuthentic(secret: secret))

        // The T3 state is signed: changing it breaks the signature.
        let tampered = RemoteResponse(version: 6, requestID: "a", timestamp: v6.timestamp, ok: true,
            state: RemoteState(awakeRequested: true, sleepPreventionEffective: true, serverName: "Mac", blockers: [],
                               t3Sleep: RemoteT3Sleep(enabled: false, summary: "T3 threads: 1 working", working: 1, sleepAt: 1_000)),
            message: "ok", signature: v6.signature)
        XCTAssertFalse(tampered.isAuthentic(secret: secret))

        // A v5 response carrying v6 fields is rejected even with a valid signature.
        let unsigned = RemoteResponse(version: 5, requestID: "a", timestamp: v6.timestamp, ok: true,
                                      state: state, message: "ok", signature: "")
        let forged = RemoteResponse(version: 5, requestID: "a", timestamp: v6.timestamp, ok: true, state: state,
                                    message: "ok", signature: RemoteAuthentication.signature(for: unsigned.canonicalPayload, secret: secret))
        XCTAssertFalse(forged.isAuthentic(secret: secret))
    }

    func testStateWithoutT3EncodesExactlyAsBefore() throws {
        // v6 must not change the signed payload of a state that has no T3 field.
        let state = RemoteState(awakeRequested: false, sleepPreventionEffective: false, serverName: "Mac")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("t3Sleep"))
    }
}
