import Foundation
import XCTest
@testable import ModafinilRemoteProtocol

final class WakeProtocolTests: XCTestCase {
    private let secret = Data(repeating: 0xa5, count: 32)
    private let now: Int64 = 1_800_000_000

    func testVersionTwoWakeRequestRoundTripAndReplay() throws {
        let request = RemoteRequest.signed(version: 2, command: .scheduleWake,
            argument: String(now + 3600), secret: secret, timestamp: now)
        let decoded = try RemoteWireCodec.decodeLine(RemoteRequest.self, from: RemoteWireCodec.encodeLine(request))
        XCTAssertEqual(decoded, request)
        let verifier = RemoteRequestVerifier(secret: secret)
        XCTAssertNoThrow(try verifier.verify(decoded, now: now))
        XCTAssertThrowsError(try verifier.verify(decoded, now: now))
        let legacy = RemoteRequest.signed(command: .scheduleWake, argument: request.argument, secret: secret, timestamp: now)
        XCTAssertThrowsError(try verifier.verify(legacy, now: now))
    }

    func testWakeTimeIsSignedAndCannotBeRemovedOrChanged() throws {
        let response = RemoteResponse.signed(version: 2, requestID: "test", ok: true,
            state: RemoteState(awakeRequested: false, sleepPreventionEffective: false,
                              serverName: "Mac", scheduledWakeAt: now + 3600),
            message: "Scheduled", secret: secret, timestamp: now)
        let data = try RemoteWireCodec.encodeLine(response)
        XCTAssertTrue(try RemoteWireCodec.decodeLine(RemoteResponse.self, from: data).isAuthentic(secret: secret))
        for wake in [nil, now + 7200] as [Int64?] {
            let tampered = RemoteResponse(version: 2, requestID: response.requestID,
                timestamp: now, ok: true,
                state: RemoteState(awakeRequested: false, sleepPreventionEffective: false,
                                  serverName: "Mac", scheduledWakeAt: wake),
                message: response.message, signature: response.signature)
            XCTAssertFalse(tampered.isAuthentic(secret: secret))
        }
    }

    func testLegacyResponseRemainsByteCompatibleDuringScheduledWake() {
        let state = RemoteState(awakeRequested: true, sleepPreventionEffective: true, serverName: "Mac")
        let scheduled = RemoteState(awakeRequested: true, sleepPreventionEffective: true,
                                   serverName: "Mac", scheduledWakeAt: now + 3600)
        let legacy = RemoteResponse.signed(requestID: "test", ok: true, state: state, message: "OK", secret: secret, timestamp: now)
        let withWake = RemoteResponse.signed(requestID: "test", ok: true, state: scheduled, message: "OK", secret: secret, timestamp: now)
        XCTAssertEqual(legacy, withWake)
        XCTAssertNil(withWake.state?.scheduledWakeAt)
        let injected = RemoteResponse(requestID: legacy.requestID, timestamp: now, ok: true,
                                      state: scheduled, message: legacy.message, signature: legacy.signature)
        XCTAssertFalse(injected.isAuthentic(secret: secret))
    }
}
